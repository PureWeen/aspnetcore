export function reserve(itemsInStock, quantity) {
  if (!Number.isInteger(quantity) || quantity <= 0) {
    throw new RangeError('Quantity must be a positive integer.');
  }
  return itemsInStock - quantity;
}
