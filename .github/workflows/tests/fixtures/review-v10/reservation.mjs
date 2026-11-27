import { reserve } from './inventory.mjs';

export function submitReservation(store, request) {
  const remaining = reserve(store.itemsInStock, request.quantity);
  store.itemsInStock = remaining;
  return remaining;
}
