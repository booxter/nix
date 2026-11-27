/* global document, FormData, fetch, window */

for (const form of document.querySelectorAll(".response-form")) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const fields = new FormData(form);
    const answer = {
      revision: Number(fields.get("revision")),
      fingerprint: fields.get("fingerprint"),
    };
    if (fields.has("choice")) {
      answer.choice = fields.get("choice");
    }
    if (fields.has("guidance")) {
      answer.guidance = fields.get("guidance");
    }
    if (fields.has("override_runtime_difference")) {
      answer.runtimeMinutes = Number(fields.get("runtime_minutes"));
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
        body: JSON.stringify(answer),
      });
      if (response.status === 204) {
        window.location.assign("/?submitted=1");
        return;
      }
      message.textContent = (await response.json()).error;
    } catch {
      message.textContent = "Could not confirm the submission. Refresh the inbox before trying again.";
    }
    message.hidden = false;
    button.disabled = false;
  });
}
