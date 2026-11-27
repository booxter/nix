/* global document, FormData, fetch, window */

for (const form of document.querySelectorAll("form[data-return-to]")) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const fields = new FormData(form);
    const request = {
      revision: Number(fields.get("revision")),
      fingerprint: fields.get("fingerprint"),
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
          "X-CSRF-Token": fields.get("csrf_token"),
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
