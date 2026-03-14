import React from 'react';
import { motion } from 'motion/react';
import { Music, FolderOpen, Save } from 'lucide-react';
import { syllable } from 'syllable';

interface HeaderProps {
  isFocused: boolean;
  setIsProjectsModalOpen: (open: boolean) => void;
  currentProjectId: string | null;
  handleSaveProject: () => void;
  lyrics: string;
}

export function Header({
  isFocused,
  setIsProjectsModalOpen,
  currentProjectId,
  handleSaveProject,
  lyrics
}: HeaderProps) {
  return (
    <motion.header
      animate={{ y: isFocused ? '-100%' : 0, opacity: isFocused ? 0 : 1 }}
      transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
      className="h-16 border-b border-white/10 flex items-center px-6 justify-between shrink-0 glass-panel absolute top-0 w-full z-20 bg-[#0a0a0a]/90 backdrop-blur-md"
    >
      <div className="flex items-center gap-2 text-white/80">
        <Music className="w-5 h-5 text-indigo-400" />
        <h1 className="font-medium tracking-wide">Lyricist AI</h1>
        <div className="h-4 w-px bg-white/20 mx-2" />
        <button
          onClick={() => setIsProjectsModalOpen(true)}
          className="text-xs font-medium text-white/60 hover:text-white flex items-center gap-1.5 px-2 py-1 rounded-md hover:bg-white/10 transition-colors cursor-pointer"
        >
          <FolderOpen className="w-3.5 h-3.5" />
          Projects
        </button>
        {!currentProjectId && (
          <button
            onClick={handleSaveProject}
            className="text-xs font-medium text-indigo-300 hover:text-indigo-200 flex items-center gap-1.5 px-2 py-1 rounded-md hover:bg-indigo-500/20 transition-colors cursor-pointer"
          >
            <Save className="w-3.5 h-3.5" />
            Save
          </button>
        )}
        {currentProjectId && (
          <span className="text-xs font-medium text-emerald-400/80 flex items-center gap-1.5 px-2 py-1">
            <Save className="w-3.5 h-3.5" />
            Saved
          </span>
        )}
      </div>
      <div className="flex flex-col items-end text-xs text-white/50">
        <span>{lyrics.split(/\s+/).filter(w => w.length > 0).length} words</span>
        <span>{syllable(lyrics)} syllables</span>
      </div>
    </motion.header>
  );
}
