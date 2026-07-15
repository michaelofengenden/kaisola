import { forwardRef } from 'react'
import {
  AlertTriangle, AppWindow, ArrowDownToLine, ArrowLeft, ArrowRight, ArrowUp,
  BadgeCheck, BarChart3, Bell, BellDot, Blocks, Bold, BookOpen, BookmarkPlus, Bot, Braces,
  Brain, Camera, Check, CheckCheck, CheckCircle2, ChevronDown, ChevronRight, ChevronUp,
  ChevronsUpDown, Circle, CircleAlert, CircleCheck, CircleDashed, CircleHelp,
  CircleX, CircuitBoard, ClipboardList, Code, Code2, Columns2, Columns3,
  Command, Compass, Copy, CornerDownRight, Crosshair, Crown, Database,
  Download, Ellipsis, Eraser, ExternalLink, Eye, File, FileCode2, FileDiff,
  FilePlus2, FileQuestion, FileSearch, FileText, FileWarning, FlaskConical,
  Focus, Folder, FolderInput, FolderMinus, FolderOpen, FolderPlus, FolderTree,
  Gauge, Gavel, GitBranch, GitBranchPlus, GitCommitHorizontal, GitCompare,
  GitMerge, GitPullRequestArrow, Github, Globe, Hash, HelpCircle, History,
  Image, Import, Inbox, Info, Italic, KeyRound, Keyboard, Layers3, Library, Lightbulb,
  Link2, List, ListChecks, ListOrdered, ListPlus, ListTodo, LoaderCircle, MapPin, Maximize2, Minimize2,
  MessageSquarePlus, Minus, Network, PackagePlus, PackageSearch, PackageX,
  PanelLeftClose, PanelLeftOpen, PanelRightClose, PanelRightOpen, PanelTop,
  PanelsTopLeft, Paperclip, PenLine, Pencil, PictureInPicture2, Pin, PinOff,
  Play, Plug, Plus, Quote, Redo2, RefreshCw, RotateCcw, RotateCw, Search, Send,
  ScanSearch, ServerCog, Settings, Settings2, ShieldAlert, ShieldCheck, ShieldQuestion,
  Sigma, SlidersHorizontal, Sparkles, Square, SquareTerminal, StickyNote, Strikethrough,
  SunMoon, Target, Terminal, TerminalSquare, ThumbsDown, ThumbsUp, Timer,
  Trash2, TriangleAlert, Undo2, Unlink, User, UserRound, Workflow, Wrench, X,
  XCircle, Zap,
} from 'lucide-react'
import type { LucideProps } from 'lucide-react'

/**
 * Every icon the app references BY NAME. A namespace import
 * (`import * as Lucide`) defeated tree-shaking and shipped the entire lucide
 * set (~1,500 icons) in the main bundle; this registry ships only what's
 * used. Adding an icon = add its named import above and its entry here —
 * an unknown name falls back to a neutral dot, so a miss is visible, not
 * a crash.
 */
const ICONS = {
  AlertTriangle, AppWindow, ArrowDownToLine, ArrowLeft, ArrowRight, ArrowUp,
  BadgeCheck, BarChart3, Bell, BellDot, Blocks, Bold, BookOpen, BookmarkPlus, Bot, Braces,
  Brain, Camera, Check, CheckCheck, CheckCircle2, ChevronDown, ChevronRight, ChevronUp,
  ChevronsUpDown, Circle, CircleAlert, CircleCheck, CircleDashed, CircleHelp,
  CircleX, CircuitBoard, ClipboardList, Code, Code2, Columns2, Columns3,
  Command, Compass, Copy, CornerDownRight, Crosshair, Crown, Database,
  Download, Ellipsis, Eraser, ExternalLink, Eye, File, FileCode2, FileDiff,
  FilePlus2, FileQuestion, FileSearch, FileText, FileWarning, FlaskConical,
  Focus, Folder, FolderInput, FolderMinus, FolderOpen, FolderPlus, FolderTree,
  Gauge, Gavel, GitBranch, GitBranchPlus, GitCommitHorizontal, GitCompare,
  GitMerge, GitPullRequestArrow, Github, Globe, Hash, HelpCircle, History,
  Image, Import, Inbox, Info, Italic, KeyRound, Keyboard, Layers3, Library, Lightbulb,
  Link2, List, ListChecks, ListOrdered, ListPlus, ListTodo, LoaderCircle, MapPin, Maximize2, Minimize2,
  MessageSquarePlus, Minus, Network, PackagePlus, PackageSearch, PackageX,
  PanelLeftClose, PanelLeftOpen, PanelRightClose, PanelRightOpen, PanelTop,
  PanelsTopLeft, Paperclip, PenLine, Pencil, PictureInPicture2, Pin, PinOff,
  Play, Plug, Plus, Quote, Redo2, RefreshCw, RotateCcw, RotateCw, Search, Send,
  ScanSearch, ServerCog, Settings, Settings2, ShieldAlert, ShieldCheck, ShieldQuestion,
  Sigma, SlidersHorizontal, Sparkles, Square, SquareTerminal, StickyNote, Strikethrough,
  SunMoon, Target, Terminal, TerminalSquare, ThumbsDown, ThumbsUp, Timer,
  Trash2, TriangleAlert, Undo2, Unlink, User, UserRound, Workflow, Wrench, X,
  XCircle, Zap,
} as const

type IconName = keyof typeof ICONS

interface IconProps extends LucideProps {
  name: string
}

/**
 * Render a lucide icon by name (so domain metadata can carry icon strings).
 * Falls back to a neutral dot if the name is unknown.
 */
export const Icon = forwardRef<SVGSVGElement, IconProps>(function Icon({ name, ...props }, ref) {
  const C = ICONS[name as IconName] ?? Circle
  return <C ref={ref} size={16} strokeWidth={1.75} {...props} />
})

export type { IconName }
