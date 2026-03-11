import { Decompress } from "fzstd";

const EMPTY = new Uint8Array(0);

export class ZstdDecompressionStream extends TransformStream {
  constructor() {
    let decompressor;
    super({
      start(controller) {
        decompressor = new Decompress((chunk, isLast) => {
          if (chunk) controller.enqueue(chunk);
          if (isLast) controller.terminate();
        });
      },
      transform(chunk) {
        decompressor.push(
          chunk instanceof Uint8Array
            ? chunk
            : new Uint8Array(
                chunk instanceof ArrayBuffer
                  ? chunk
                  : chunk.buffer, chunk.byteOffset, chunk.byteLength
              )
        );
      },
      flush() {
        decompressor.push(EMPTY, true);
        decompressor = undefined; // GC解放
      },
    });
  }
}
