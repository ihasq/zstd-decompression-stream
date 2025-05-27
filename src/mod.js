import { Decompress } from "fzstd";

export class ZstdDecompressionStream extends TransformStream {

	constructor() {

		super({

			start(controller) {
				this.decompressor = new Decompress((chunk, isLast) => {
					if (chunk) controller.enqueue(chunk);
					if (isLast) controller.terminate();
				});
			},

			transform(chunk) {
				this.decompressor.push(
					chunk instanceof Uint8Array
						? chunk
						: new Uint8Array(chunk)
				);
			},
		
			flush() {
				this.decompressor.push(
					new Uint8Array(0),
					true
				);
			}
		});
	}
}