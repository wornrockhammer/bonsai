# Bonsai Project Board UI Design Specification

Date: 2026-02-04

## Reference Design

**Reference Image:** `.claude/bonsai/assets/project-board-reference.png`

This document provides a complete specification for recreating the Bonsai project board UI using **Tailwind CSS 4**. The design follows a dark theme with colored accents, kanban-style columns, and a modern SaaS aesthetic.

---

## Tailwind 4 Theme Configuration

Tailwind 4 uses CSS-first configuration. Add this to your main CSS file:

```css
@import "tailwindcss";

@theme {
  /* Custom gray scale (sampled from reference) */
  --color-gray-950: #0A0A0C;
  --color-gray-900: #111114;
  --color-gray-800: #17171B;
  --color-gray-700: #1E1E23;
  --color-gray-600: #2A2A30;
  --color-gray-500: #4B5563;
  --color-gray-400: #6B7280;
  --color-gray-300: #9CA3AF;
  --color-gray-200: #D1D5DB;

  /* Accent colors */
  --color-accent-blue: #3B82F6;
  --color-accent-purple: #8B5CF6;
  --color-accent-teal: #14B8A6;
  --color-accent-green: #22C55E;
  --color-accent-orange: #F97316;
  --color-accent-yellow: #FBBF24;

  /* Semantic aliases */
  --color-bg-primary: var(--color-gray-950);
  --color-bg-sidebar: var(--color-gray-900);
  --color-bg-card: var(--color-gray-800);
  --color-bg-card-hover: var(--color-gray-700);
  --color-bg-input: #1A1A1F;

  /* Custom shadows */
  --shadow-card: 0 1px 2px rgba(0, 0, 0, 0.4);
  --shadow-elevated: 0 4px 20px rgba(0, 0, 0, 0.6);
  --shadow-glow: 0 0 16px rgba(59, 130, 246, 0.25);
  --shadow-drag: 0 12px 32px rgba(0, 0, 0, 0.6);
}
```

---

## Color Palette

### Backgrounds
| Token | Tailwind Class | Hex |
|-------|---------------|-----|
| Primary bg | `bg-gray-950` | `#0A0A0C` |
| Sidebar | `bg-gray-900` | `#111114` |
| Card | `bg-gray-800` | `#17171B` |
| Card hover | `bg-gray-700` | `#1E1E23` |
| Input | `bg-[#1A1A1F]` | `#1A1A1F` |

### Text
| Token | Tailwind Class | Hex |
|-------|---------------|-----|
| Primary | `text-white` | `#FFFFFF` |
| Secondary | `text-gray-300` | `#9CA3AF` |
| Muted | `text-gray-400` | `#6B7280` |
| Disabled | `text-gray-500` | `#4B5563` |

### Accents
| Token | Tailwind Class | Hex |
|-------|---------------|-----|
| Blue | `bg-blue-500` / `text-blue-500` | `#3B82F6` |
| Purple | `bg-violet-500` | `#8B5CF6` |
| Teal | `bg-teal-500` | `#14B8A6` |
| Green | `bg-green-500` | `#22C55E` |
| Orange | `bg-orange-500` | `#F97316` |
| Yellow | `bg-amber-400` | `#FBBF24` |

### Tag Colors
| Category | Classes |
|----------|---------|
| Design | `bg-violet-500 text-white` |
| Development | `bg-green-500 text-white` |
| Marketing | `bg-orange-500 text-white` |
| Content | `bg-amber-400 text-black` |
| Improvement | `bg-teal-500 text-white` |

### Status Dots
| Status | Classes |
|--------|---------|
| Backlog | `bg-gray-400` |
| In Progress | `bg-amber-400` |
| Review | `bg-blue-500` |
| Done | `bg-green-500` |

---

## Typography

Use **Inter** font via `font-sans` (configure in theme or add Google Fonts).

| Element | Classes |
|---------|---------|
| Page title | `text-xl font-semibold text-white` |
| Column header | `text-sm font-medium text-white` |
| Card title | `text-sm font-medium text-white` |
| Card description | `text-[13px] text-gray-300` |
| Tag label | `text-[11px] font-medium` |
| Due date | `text-xs text-gray-400` |
| Button | `text-sm font-medium` |

---

## Layout Structure

### Overall Layout (Two-Panel)

```jsx
<div className="flex h-screen bg-gray-950">
  {/* Left Sidebar */}
  <aside className="w-16 shrink-0 bg-gray-900 border-r border-gray-700">
    {/* ... */}
  </aside>

  {/* Main Content */}
  <main className="flex-1 overflow-hidden">
    {/* Header + Board */}
  </main>
</div>
```

### Left Sidebar

```jsx
<aside className="w-16 shrink-0 flex flex-col items-center py-4 bg-gray-900 border-r border-gray-700">
  {/* Logo */}
  <div className="size-12 mb-6">
    <img src="/logo.svg" alt="Bonsai" className="size-full" />
  </div>

  {/* Nav Items */}
  <nav className="flex flex-col gap-2">
    {/* Active */}
    <button className="size-10 flex items-center justify-center rounded-lg bg-gray-800 text-blue-500">
      <LayoutGrid className="size-5" />
    </button>

    {/* Inactive */}
    <button className="size-10 flex items-center justify-center rounded-lg text-gray-400 hover:bg-gray-700 hover:text-white transition-colors">
      <Home className="size-5" />
    </button>
  </nav>

  {/* User Avatar (bottom) */}
  <div className="mt-auto">
    <img src="/avatar.jpg" className="size-10 rounded-full" />
  </div>
</aside>
```

### Top Header Bar

```jsx
<header className="h-14 px-6 flex items-center justify-between border-b border-gray-700">
  {/* Left: Project name + view toggles */}
  <div className="flex items-center gap-6">
    <h1 className="text-xl font-semibold text-white">Publications</h1>

    {/* View Toggles */}
    <div className="flex gap-1">
      <button className="px-3 py-1.5 text-sm text-gray-400 hover:text-white rounded-md">
        <List className="size-4 inline mr-1.5" />
        List
      </button>
      <button className="px-3 py-1.5 text-sm text-white bg-gray-800 border border-gray-700 rounded-md">
        <LayoutGrid className="size-4 inline mr-1.5" />
        Board
      </button>
      <button className="px-3 py-1.5 text-sm text-gray-400 hover:text-white rounded-md">
        <Calendar className="size-4 inline mr-1.5" />
        Calendar
      </button>
    </div>
  </div>

  {/* Right: Add task + more */}
  <div className="flex items-center gap-3">
    <button className="h-9 px-4 flex items-center gap-2 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-lg transition-colors">
      <Plus className="size-4" />
      Add task
    </button>
    <button className="size-9 flex items-center justify-center text-gray-400 hover:text-white rounded-lg hover:bg-gray-700">
      <MoreHorizontal className="size-5" />
    </button>
  </div>
</header>

{/* Search/Filter Row */}
<div className="h-12 px-6 flex items-center justify-between border-b border-gray-700">
  <div className="relative">
    <Search className="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-gray-400" />
    <input
      type="text"
      placeholder="Search tasks..."
      className="w-60 h-9 pl-10 pr-4 bg-[#1A1A1F] border border-gray-700 rounded-lg text-sm text-white placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500/20"
    />
  </div>

  <div className="flex items-center gap-4">
    <button className="flex items-center gap-2 text-sm text-gray-300 hover:text-white">
      <SlidersHorizontal className="size-4" />
      Filters
    </button>
    <button className="flex items-center gap-2 text-sm text-gray-300 hover:text-white">
      <User className="size-4" />
      Me
    </button>
  </div>
</div>
```

### Board Columns

```jsx
<div className="flex gap-4 p-6 overflow-x-auto">
  {/* Column */}
  <div className="w-70 shrink-0 flex flex-col">
    {/* Column Header */}
    <div className="flex items-center gap-2 mb-4">
      <span className="size-2 rounded-full bg-gray-400" /> {/* Status dot */}
      <span className="text-sm font-medium text-white">Backlog</span>
      <span className="text-sm text-gray-400">(12)</span>
    </div>

    {/* Cards Container */}
    <div className="flex flex-col gap-3 overflow-y-auto">
      {/* Cards go here */}
    </div>
  </div>

  {/* Repeat for other columns with different status dot colors */}
</div>
```

---

## Components

### Task Card

```jsx
<div className="p-3 bg-gray-800 border border-gray-700 rounded-xl hover:bg-gray-700 hover:-translate-y-0.5 hover:shadow-lg transition-all cursor-pointer">
  {/* Header: Tag + Due Date */}
  <div className="flex items-center justify-between mb-2">
    <span className="px-2 py-1 text-[11px] font-medium bg-violet-500 text-white rounded-md">
      Design
    </span>
    <span className="text-xs text-orange-500">Due in Today</span>
  </div>

  {/* Title */}
  <h3 className="text-sm font-medium text-white mb-1 line-clamp-2">
    Mobile App Dashboard Redesign
  </h3>

  {/* Description */}
  <p className="text-[13px] text-gray-300 line-clamp-3">
    Redesign the dashboard UI for the mobile app to improve usability and visual clarity.
  </p>

  {/* Footer */}
  <div className="flex items-center justify-between mt-3 pt-3 border-t border-gray-700">
    {/* Assignees */}
    <div className="flex -space-x-2">
      <img src="/avatar1.jpg" className="size-7 rounded-full border-2 border-gray-800" />
      <img src="/avatar2.jpg" className="size-7 rounded-full border-2 border-gray-800" />
      <span className="size-7 flex items-center justify-center rounded-full bg-gray-600 text-[11px] font-medium text-gray-300 border-2 border-gray-800">
        +2
      </span>
    </div>

    {/* Actions */}
    <div className="flex items-center gap-3 text-gray-400">
      <button className="hover:text-gray-200"><MessageSquare className="size-4" /></button>
      <button className="hover:text-gray-200"><Paperclip className="size-4" /></button>
      <button className="hover:text-gray-200"><Calendar className="size-4" /></button>
    </div>
  </div>
</div>
```

### Primary Button

```jsx
<button className="h-9 px-4 flex items-center gap-2 bg-blue-500 hover:bg-blue-600 text-white text-sm font-medium rounded-lg shadow-sm hover:shadow-glow transition-all">
  <Plus className="size-4" />
  Add task
</button>
```

### Secondary Button

```jsx
<button className="h-9 px-4 flex items-center gap-2 bg-transparent border border-gray-700 text-gray-300 hover:bg-gray-800 hover:text-white text-sm font-medium rounded-lg transition-colors">
  Cancel
</button>
```

### Icon Button

```jsx
<button className="size-9 flex items-center justify-center text-gray-400 hover:text-white hover:bg-gray-700 rounded-lg transition-colors">
  <MoreHorizontal className="size-5" />
</button>
```

### Form Input

```jsx
<input
  type="text"
  placeholder="Search..."
  className="w-full h-9 px-3 bg-[#1A1A1F] border border-gray-700 rounded-lg text-sm text-white placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500/20 transition-colors"
/>
```

### Tags

```jsx
{/* Design - Purple */}
<span className="px-2 py-1 text-[11px] font-medium bg-violet-500 text-white rounded-md">Design</span>

{/* Development - Green */}
<span className="px-2 py-1 text-[11px] font-medium bg-green-500 text-white rounded-md">Development</span>

{/* Marketing - Orange */}
<span className="px-2 py-1 text-[11px] font-medium bg-orange-500 text-white rounded-md">Marketing</span>

{/* Content - Yellow */}
<span className="px-2 py-1 text-[11px] font-medium bg-amber-400 text-black rounded-md">Content</span>

{/* Improvement - Teal */}
<span className="px-2 py-1 text-[11px] font-medium bg-teal-500 text-white rounded-md">Improvement</span>
```

### Avatar Stack

```jsx
<div className="flex -space-x-2">
  <img src="/avatar1.jpg" className="size-7 rounded-full border-2 border-gray-800 object-cover" />
  <img src="/avatar2.jpg" className="size-7 rounded-full border-2 border-gray-800 object-cover" />
  <span className="size-7 flex items-center justify-center rounded-full bg-gray-600 text-[11px] font-medium text-gray-300 border-2 border-gray-800">
    +2
  </span>
</div>
```

### Status Dot

```jsx
{/* Backlog */}
<span className="size-2 rounded-full bg-gray-400" />

{/* In Progress */}
<span className="size-2 rounded-full bg-amber-400" />

{/* Review */}
<span className="size-2 rounded-full bg-blue-500" />

{/* Done */}
<span className="size-2 rounded-full bg-green-500" />
```

---

## Interactions

### Drag and Drop (Card Grab Effect)

When grabbed, the card has a **rotation + zoom** effect:

```jsx
{/* Normal state */}
<div className="... transition-all duration-100">

{/* Dragging state - add these classes dynamically */}
<div className="... rotate-3 scale-105 opacity-95 shadow-drag cursor-grabbing z-50">
```

**Key utilities:**
- `rotate-3` — Slight tilt for "picked up" feel
- `scale-105` — Zoom lift effect
- `shadow-drag` — Custom deep shadow (defined in theme)
- `transition-all duration-100` — Smooth 100ms pickup

### Drop Zone

```jsx
{/* Active drop zone */}
<div className="bg-blue-500/10 border-2 border-dashed border-blue-500 rounded-xl">
```

### Card Hover

```jsx
<div className="... hover:bg-gray-700 hover:-translate-y-0.5 hover:shadow-lg transition-all">
```

### Loading States

```jsx
{/* Skeleton card */}
<div className="p-3 bg-gray-800 border border-gray-700 rounded-xl animate-pulse">
  <div className="h-5 w-20 bg-gray-700 rounded mb-2" />
  <div className="h-4 w-full bg-gray-700 rounded mb-1" />
  <div className="h-4 w-3/4 bg-gray-700 rounded" />
</div>

{/* Spinner */}
<div className="size-6 border-2 border-blue-500 border-t-transparent rounded-full animate-spin" />
```

---

## Bonsai-Specific Adaptations

### Column Names

| Reference | Bonsai | Dot Class |
|-----------|--------|-----------|
| To Do | **Backlog** | `bg-gray-400` |
| In Progress | **In Progress** | `bg-amber-400` |
| Review | **Review** | `bg-blue-500` |
| Completed | **Done** | `bg-green-500` |

### Ticket Card with Persona

```jsx
<div className="p-3 bg-gray-800 border border-gray-700 rounded-xl">
  {/* Header: Project + Persona + Estimate */}
  <div className="flex items-center gap-2 mb-2">
    <span className="px-2 py-1 text-[11px] font-medium bg-violet-500 text-white rounded-md">Frontend</span>
    <span className="px-2 py-1 text-[11px] font-medium bg-green-500/20 text-green-400 rounded-md">Devon</span>
    <span className="ml-auto text-xs text-gray-400">Est: 2h</span>
  </div>

  {/* Title + Description */}
  <h3 className="text-sm font-medium text-white mb-1">Implement user authentication</h3>
  <p className="text-[13px] text-gray-300 line-clamp-2">Add OAuth2 login flow with Google and GitHub providers.</p>

  {/* Footer with persona avatar + activity */}
  <div className="flex items-center justify-between mt-3 pt-3 border-t border-gray-700">
    <div className="flex items-center gap-2">
      <div className="size-6 rounded-full bg-green-500/20 flex items-center justify-center">
        <span className="text-[10px]">🤖</span>
      </div>
      <span className="text-xs text-gray-300">Devon</span>
    </div>
    <div className="flex items-center gap-2 text-xs text-green-400">
      <Zap className="size-3" />
      Active
    </div>
  </div>
</div>
```

### Persona Colors

| Persona | Accent Class |
|---------|--------------|
| Devon (Developer) | `bg-green-500` / `text-green-400` |
| Riley (Reviewer) | `bg-blue-500` / `text-blue-400` |
| Morgan (Researcher) | `bg-violet-500` / `text-violet-400` |
| Jamie (DevOps) | `bg-orange-500` / `text-orange-400` |
| Project Manager | `bg-teal-500` / `text-teal-400` |

---

## Responsive Behavior

### Breakpoints (Tailwind defaults)

| Breakpoint | Prefix | Width |
|------------|--------|-------|
| Mobile | (none) | <640px |
| Tablet | `sm:` | 640px+ |
| Desktop | `md:` | 768px+ |
| Large | `lg:` | 1024px+ |
| XL | `xl:` | 1280px+ |

### Mobile Layout

```jsx
{/* Sidebar becomes bottom nav on mobile */}
<aside className="fixed bottom-0 left-0 right-0 h-14 flex items-center justify-around bg-gray-900 border-t border-gray-700 md:relative md:w-16 md:h-auto md:flex-col md:border-r md:border-t-0">
```

### Column Scroll

```jsx
{/* Horizontal scroll on smaller screens */}
<div className="flex gap-4 p-6 overflow-x-auto snap-x snap-mandatory md:snap-none">
  <div className="w-70 shrink-0 snap-center">
    {/* Column content */}
  </div>
</div>
```

---

## Icons

Use **Lucide React**:

```bash
npm install lucide-react
```

```jsx
import {
  Home, LayoutGrid, List, Calendar, Settings,
  Plus, Search, SlidersHorizontal, MessageSquare,
  Paperclip, MoreHorizontal, User, Zap
} from 'lucide-react';
```

---

## Implementation Stack

- **Framework:** React 19 / Next.js 15
- **Styling:** Tailwind CSS 4
- **Drag/Drop:** `@dnd-kit/core`
- **Icons:** `lucide-react`
- **Fonts:** Inter (Google Fonts or `@fontsource/inter`)
- **State:** Zustand
- **Animation:** Tailwind transitions + Framer Motion for complex animations

---

## Summary

This spec provides Tailwind 4-native implementation for the Bonsai project board:

1. **Theme config** — CSS-first `@theme` block with custom colors
2. **Utility classes** — No custom CSS, all Tailwind utilities
3. **Component examples** — Copy-paste JSX with full class lists
4. **Interactions** — Drag/drop, hover, loading states
5. **Bonsai adaptations** — Persona badges, activity indicators
6. **Responsive** — Mobile-first with breakpoint utilities

Reference the screenshot at `.claude/bonsai/assets/project-board-reference.png` for visual verification.
