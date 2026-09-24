import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  build: {
    target: 'es2015',
    outDir: resolve(process.cwd(), 'dist'),
    emptyOutDir: true,
    lib: {
      entry: resolve(process.cwd(), 'src/index.ts'),
      formats: ['cjs'],
      fileName: () => 'nospy-dns-filter.js',
    },
    rollupOptions: {
      external: [
        'dgram',
        'dns',
        'fs',
        'net',
      ],
    },
  },
});
