/** A deadline limits the caller's wait, never pretends to cancel a platform API. */
export async function deadline<T>(work: Promise<T>, milliseconds: number, message: string): Promise<T> {
  let timer: number = -1;
  const limit = new Promise<T>((_resolve, reject) => {
    timer = setTimeout(() => { reject(new Error(message)); }, milliseconds);
  });
  try { return await Promise.race([work, limit]); }
  finally { if (timer >= 0) clearTimeout(timer); }
}
