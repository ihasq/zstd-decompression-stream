import { Decompress } from "fzstd";

const EMPTY = new Uint8Array(0);

type BufferSource = ArrayBufferView | ArrayBuffer;

const toU8 = (chunk: BufferSource): Uint8Array =>
  chunk instanceof Uint8Array
    ? chunk
    : chunk instanceof ArrayBuffer
      ? new Uint8Array(chunk)
      : new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);

export class ZstdDecompressionStream extends TransformStream<BufferSource, Uint8Array> {
  constructor() {
    let decompressor: Decompress | undefined;
    super({
      start(controller) {
        decompressor = new Decompress((chunk: Uint8Array) => {
          controller.enqueue(chunk);
        });
      },
      transform(chunk) {
        decompressor!.push(toU8(chunk));
      },
      flush() {
        decompressor!.push(EMPTY, true);
        decompressor = undefined;
      },
    });
  }
}
