/* global document */

// append() treats strings from the API as text, including file names and planner replies.
export function element(tag, attributes, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    node.setAttribute(name, value);
  }
  node.append(...children);
  return node;
}

const localTime = new Intl.DateTimeFormat(undefined, {
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short",
});

export function timestamp(value) {
  return element("time", { datetime: value }, localTime.format(new Date(value)));
}
