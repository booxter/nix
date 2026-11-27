/* global document, window, URL, fetch, element, timestamp, answerForm */

function jobLink(job, label) {
  return element("a", { href: "/jobs/" + job.id }, label);
}

function inboxItem(job) {
  const article = element("article", { class: "action-item" },
    element("div", { class: "item-heading" },
      element("span", { class: "service" }, job.service), element("span", { class: "badge" }, job.status)),
    element("h3", {}, jobLink(job, job.subject)),
    element("p", { class: "case-explanation" }, job.explanation));
  if (job.actions.answer && job.question) article.append(answerForm(job));

  const links = element("div", { class: "item-links" }, jobLink(job, "Details"));
  if (job.actions.remove) {
    links.append(element("a", { href: "/jobs/" + job.id + "/remove" }, "Remove from queue…"));
  }
  article.append(links);
  if (job.subject !== job.title) {
    article.append(element("details", { class: "release-name" },
      element("summary", {}, "Download name"), element("p", {}, job.title)));
  }
  return article;
}

function activityRow(job) {
  const explanation = element("td", {}, job.explanation);
  if (job.nextStep) explanation.append(element("small", {}, job.nextStep));
  return element("tr", {},
    element("td", {}, element("span", { class: "service" }, job.service)),
    element("td", {}, jobLink(job, job.subject)), element("td", {}, job.status),
    explanation, element("td", {}, timestamp(job.updatedAt)));
}

async function loadListing(list) {
  const status = list.querySelector('[role="status"]');
  const url = new URL(list.dataset.api, window.location.href);
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error();
    const jobs = await response.json();
    const inbox = list.querySelector(".action-inbox");
    const inboxCount = document.querySelector('[data-count="inbox"]');
    if (inboxCount) inboxCount.textContent = response.headers.get("X-Inbox-Count");

    const query = url.searchParams.get("q")?.trim();
    status.className = "result-count";
    status.textContent = jobs.length + (jobs.length === 1 ? " item" : " items");
    if (query) status.append(" matching “" + query + "”");
    if (jobs.length === 0) {
      if (inbox && !query) {
        inbox.append(element("div", { class: "empty" }, element("h2", {}, "Nothing needs your input right now."),
          element("p", {}, "Other downloads may still be waiting, processing or blocked by technical problems. ",
            element("a", { href: "/activity" }, "See queue activity (" + response.headers.get("X-Activity-Count") + ")"))));
      } else {
        list.append(element("p", { class: "empty" }, "No entries match this view."));
      }
    } else if (inbox) {
      inbox.append(...jobs.map(inboxItem));
    } else {
      list.querySelector("tbody").append(...jobs.map(activityRow));
      list.querySelector(".table-wrap").hidden = false;
    }
  } catch {
    status.textContent = "Could not load items. Refresh the page to try again.";
  }
}

loadListing(document.getElementById("listing"));
