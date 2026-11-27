/* global document, window, URL, fetch, bindAction, localTime */

// append() treats strings from the API as text, including file names and planner replies.
function element(tag, attributes, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    node.setAttribute(name, value);
  }
  node.append(...children);
  return node;
}

function timestamp(value) {
  return element("time", { datetime: value }, localTime.format(new Date(value)));
}

function row(list, label, value) {
  if (value) list.append(element("dt", {}, label), element("dd", {}, value));
}

function technicalDetails(job) {
  const list = element("dl", {});
  row(list, "Release", job.title);
  row(list, "Job / queue", "#" + job.id + " / #" + job.queueId);
  row(list, "Last checked", timestamp(job.updatedAt));
  row(list, "Internal state", job.state);
  row(list, "Inspection problem", job.inspectionError);
  row(list, "Recorded reason", job.reason);
  if (job.decision) {
    row(list, "Last planner action", [job.decision.action, job.decision.reason].filter(Boolean).join(" · "));
    row(list, "Last explanation", job.decision.explanation);
  }
  return element("details", { class: "technical-details" },
    element("summary", {}, "Release and technical details"), list);
}

function attemptDetails(attempt) {
  const section = element("section", { class: "decision" },
    element("h3", {}, "Attempt " + attempt.number + " · " + attempt.state));
  if (attempt.reason) section.append(element("p", {}, attempt.reason));
  if (attempt.commandId) section.append(element("p", {}, "Import command #" + attempt.commandId));
  if (attempt.outputPath) section.append(element("p", {}, element("code", {}, attempt.outputPath)));
  if (attempt.receipt) {
    const files = element("ul", { class: "imported-files" });
    for (const file of attempt.receipt.files) {
      const paths = element("dl", {});
      row(paths, "Source path", element("code", {}, file.droppedPath));
      row(paths, "Library path", element("code", {}, file.importedPath));
      files.append(element("li", {}, paths));
    }
    section.append(element("details", {}, element("summary", {},
      "Imported files (" + attempt.receipt.files.length + ")"), files));
  }
  return section;
}

function actionForm(job, action, ...controls) {
  const form = element("form", {
    method: "post", action: "/api/jobs/" + job.id + "/" + action,
    "data-return-to": action === "answer" ? "/?submitted=1" : "/jobs/" + job.id,
  });
  for (const [name, value] of Object.entries({
    csrf_token: job.csrfToken, revision: job.revision, fingerprint: job.fingerprint,
  })) {
    form.append(element("input", { type: "hidden", name, value }));
  }
  form.append(...controls, element("p", { role: "alert", hidden: "" }));
  bindAction(form);
  return form;
}

function guidance(label, job, required = false) {
  const input = element("textarea", { name: "guidance", maxlength: 2000 }, job.guidance || "");
  input.required = required;
  return element("label", {}, label, input);
}

function runtimeLimit(required, initialValue = "") {
  const minutes = element("input", {
    name: "runtime_minutes", type: "number", min: 1, max: 60, value: initialValue,
  });
  minutes.required = required;
  const override = element("input", {
    type: required ? "hidden" : "checkbox", name: "override_runtime_difference", value: "on",
  });
  return element("fieldset", {}, element("legend", {}, "Runtime difference you accept"),
    required ? override : element("label", { class: "check" }, override, " Accept a larger difference"),
    element("label", {}, "Maximum difference in minutes", minutes));
}

function answerForm(job) {
  const question = job.question;
  const controls = [element("h4", {}, question.text)];
  if (question.context?.length) {
    controls.push(element("details", { class: "evidence-context" },
      element("summary", {}, "Files and media information"),
      element("ul", {}, ...question.context.map(line => element("li", {}, line)))));
  }
  if (question.choices?.length) {
    const select = element("select", { name: "choice", required: "" },
      element("option", { value: "", disabled: "", selected: "" }, "Choose…"));
    for (const choice of question.choices) {
      select.append(element("option", { value: choice.value }, choice.label));
    }
    controls.push(element("label", {}, "Your choice", select));
  }
  if (question.hint) controls.push(element("p", { class: "input-hint" }, question.hint));
  if (question.kind !== "retry") {
    controls.push(guidance(question.requireGuidance ? "Your instructions" : "Additional instructions (optional)",
      job, question.requireGuidance));
  }
  if (question.allowRuntime) controls.push(runtimeLimit(question.kind === "runtime"));
  const form = actionForm(job, "answer", ...controls, element("button", { type: "submit" }, question.button));
  form.className = "response-form";
  return form;
}

function reconsiderForm(job) {
  const controls = [guidance("Guidance", job)];
  if (job.service === "radarr") controls.push(runtimeLimit(false, "15"));
  return element("details", { class: "nudge" }, element("summary", {}, "Advanced: request a new review"),
    actionForm(job, "reconsider", ...controls, element("button", { type: "submit" }, "Reconsider")));
}

function confirmRemoval(job) {
  return element("section", { class: "remove-confirmation" },
    element("h3", {}, "Remove from " + job.service + " queue?"),
    element("p", {}, "This removes the queue entry. SABnzbd downloads and their remaining files are deleted. Torrents and library files are kept. The release is not blocklisted."),
    actionForm(job, "remove", element("button", { class: "danger-button", type: "submit" }, "Remove from queue"),
      element("a", { class: "button secondary-button", href: "/jobs/" + job.id }, "Cancel")));
}

function showJob(container, job) {
  const actions = element("div", { class: "case-actions" }, element("span", { class: "badge" }, job.status));
  if (job.actions.remove) {
    actions.append(element("a", {
      class: "remove-link", href: "/jobs/" + job.id + "/remove", title: "Remove from queue",
    }, "×"));
  }
  container.replaceChildren(element("div", { class: "case-heading" },
    element("div", {}, element("span", { class: "service" }, job.service), element("h2", {}, job.subject)),
    actions), element("p", { class: "case-explanation" }, job.explanation));

  const removing = job.actions.remove && window.location.pathname.endsWith("/remove");
  if (!removing && job.actions.answer && job.question) {
    container.append(answerForm(job));
  } else if (job.retryAt || job.nextStep) {
    container.append(element("p", { class: "next-step" },
      element("strong", {}, job.retryAt ? "Next retry: " : "Next step: "),
      job.retryAt ? timestamp(job.retryAt) : job.nextStep));
  }
  container.append(technicalDetails(job));
  if (removing) container.append(confirmRemoval(job));
  else if (job.actions.reconsider) container.append(reconsiderForm(job));
  for (const attempt of job.attempts) container.append(attemptDetails(attempt));
  if (job.queueUrl && ["http:", "https:"].includes(new URL(job.queueUrl, window.location.href).protocol)) {
    container.append(element("p", {}, element("a", { class: "button", href: job.queueUrl },
      "Open " + job.service + " queue")));
  }
}

async function loadJob(container) {
  try {
    const response = await fetch(container.dataset.api);
    const job = await response.json();
    if (!response.ok) {
      container.textContent = job.error || "Could not load this item.";
      return;
    }
    showJob(container, job);
  } catch {
    container.textContent = "Could not load this item. Refresh the page to try again.";
  }
}

loadJob(document.getElementById("job"));
