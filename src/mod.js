import { Decompress } from "fzstd";

const EMPTY = new Uint8Array(0);

const toU8 = (chunk) => (
  (chunk instanceof Uint8Array)    ? chunk
  : (chunk instanceof ArrayBuffer) ? new Uint8Array(chunk)
  :                                  new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength)
);

export class ZstdDecompressionStream extends TransformStream {
  constructor() {
    let decompressor;
    super({
      start(controller) {
        decompressor = new Decompress((chunk) => {
          controller.enqueue(chunk);
        });
      },
      transform(chunk) {
        decompressor.push(toU8(chunk));
      },
      flush() {
        decompressor.push(EMPTY, true);
        decompressor = undefined;
      },
    });
  }
}
