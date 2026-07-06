/** Map a file extension to a lucide icon name (workspace tree + editor bar). */
export function fileIcon(name: string): string {
  const ext = name.split('.').pop()?.toLowerCase()
  switch (ext) {
    case 'md':
    case 'markdown':
    case 'mdx':
      return 'FileText'
    case 'tex':
    case 'latex':
      return 'Sigma'
    case 'ts':
    case 'tsx':
    case 'js':
    case 'jsx':
    case 'mjs':
    case 'cjs':
    case 'py':
      return 'FileCode2'
    case 'json':
      return 'Braces'
    case 'pdf':
      return 'FileText'
    case 'css':
    case 'scss':
      return 'Hash'
    case 'html':
    case 'htm':
    case 'xml':
    case 'svg':
      return 'Code2'
    case 'png':
    case 'apng':
    case 'jpg':
    case 'jpeg':
    case 'jfif':
    case 'gif':
    case 'webp':
    case 'avif':
    case 'bmp':
    case 'ico':
      return 'Image'
    case 'yml':
    case 'yaml':
      return 'Settings2'
    default:
      return 'File'
  }
}
