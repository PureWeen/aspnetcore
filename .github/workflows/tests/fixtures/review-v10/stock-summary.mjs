export function countAvailable(items) {
  return items.filter(item => !item.available).length;
}

export function countUnavailable(items) {
  return items.filter(item => !item.available).length;
}

export function describeStock(items) {
  return `${countAvailable(items)} available out of ${items.length}`;
}
