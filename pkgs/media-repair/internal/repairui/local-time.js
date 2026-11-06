/* global document */

const localTime = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short",
});

for (const element of document.querySelectorAll("time[datetime]")) {
  element.textContent = localTime.format(new Date(element.dateTime));
}
