/* global document, FormData, fetch, window */

function bindAction(form, job) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const fields = new FormData(form);
    const request = {
      revision: job.revision,
      fingerprint: job.fingerprint,
    };
    if (fields.has("choice")) {
      request.choice = fields.get("choice");
    }
    if (fields.has("guidance")) {
      request.guidance = fields.get("guidance");
    }
    if (fields.has("override_runtime_difference")) {
      request.runtimeMinutes = Number(fields.get("runtime_minutes"));
    }

    const button = form.querySelector("button");
    const message = form.querySelector('[role="alert"]');
    button.disabled = true;
    message.hidden = true;
    try {
      const response = await fetch(form.action, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": job.csrfToken,
        },
        body: JSON.stringify(request),
      });
      if (response.status === 204) {
        window.location.assign(form.dataset.returnTo);
        return;
      }
      message.textContent = (await response.json()).error;
    } catch {
      message.textContent = "Could not confirm the submission. Refresh the page before trying again.";
    }
    message.hidden = false;
    button.disabled = false;
  });
}

// append() treats strings from the API as text, including file names and planner replies.
function element(tag, attributes, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    node.setAttribute(name, value);
  }
  node.append(...children);
  return node;
}

function actionForm(job, action, ...controls) {
  const form = element("form", {
    method: "post", action: "/api/jobs/" + job.id + "/" + action,
    "data-return-to": action === "answer" ? "/?submitted=1" : "/jobs/" + job.id,
  });
  form.append(...controls, element("p", { role: "alert", hidden: "" }));
  bindAction(form, job);
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
