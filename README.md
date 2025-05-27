# zstd-decompression-stream

## Usage
```javascript
import { ZstdDecompressionStream } from "zstd-decompression-stream";

fetch("./path/to/blob.zst").then(res => res.body.pipeThrough(new ZstdDecompressionStream()))
```

## License
zstd-decompression-stream is [MIT Licensed](./LICENSE).