declare module "fzstd" {
  export class Decompress {
    constructor(onChunk: (chunk: Uint8Array) => void);
    push(chunk: Uint8Array, final?: boolean): void;
  }
}
