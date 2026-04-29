export function clamp(val: number, min: number, max: number): number {
  return val < min ? min : val > max ? max : val;
}

export function distSq(ax: number, ay: number, bx: number, by: number): number {
  return (ax - bx) * (ax - bx) + (ay - by) * (ay - by);
}
