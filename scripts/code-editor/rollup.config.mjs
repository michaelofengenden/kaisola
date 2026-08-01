import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { nodeResolve } from '@rollup/plugin-node-resolve'
import terser from '@rollup/plugin-terser'

const directory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(directory, '../..')
const defaultOutput = path.join(
  repositoryRoot,
  'native/KaisolaMac/Kaisola/Resources/CodeEditor/editor.bundle.js',
)

export default {
  input: path.join(directory, 'editor.mjs'),
  output: {
    file: process.env.KAISOLA_CODE_EDITOR_OUTPUT || defaultOutput,
    format: 'iife',
    name: 'KaisolaCodeEditorRuntime',
    sourcemap: false,
  },
  plugins: [
    nodeResolve({ browser: true }),
    terser({
      compress: { passes: 2 },
      format: { comments: false },
      mangle: true,
    }),
  ],
}
