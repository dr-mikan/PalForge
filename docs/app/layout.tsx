import type { ReactNode } from 'react';
import './global.css';

// The locale-aware <html> lives in app/[lang]/layout.tsx; this root only exists because
// Next requires one, and to carry the stylesheet.
export default function RootLayout({ children }: { children: ReactNode }) {
  return children;
}
