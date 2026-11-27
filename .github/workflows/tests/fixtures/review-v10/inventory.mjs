export function reserve(itemsInStock, quantity) {
  if (!Number.isInteger(quantity) || quantity <= 0) {
    throw new RangeError('Quantity must be a positive integer.');
  }
  if (quantity > itemsInStock) {
    throw new RangeError('Not enough stock to reserve this quantity.');
  }
  return itemsInStock - quantity;
}
