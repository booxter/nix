/* global document */

const localTime = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short",
});

function timestamp(value) {
  return element("time", { datetime: value }, localTime.format(new Date(value)));
}
