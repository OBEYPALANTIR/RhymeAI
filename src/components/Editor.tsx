import React, { useEffect } from 'react';
import { motion } from 'motion/react';
import { syllable } from 'syllable';

interface EditorProps {
  isFocused: boolean;
  setIsFocused: (focused: boolean) => void;
  scrollY: number;
  setScrollY: (y: number) => void;
  title: string;
  setTitle: (title: string) => void;
  lyrics: string;
  setLyrics: (lyrics: string) => void;
  setCursorPosition: (pos: number) => void;
  textareaRef: React.RefObject<HTMLTextAreaElement>;
  isSyllableColoringEnabled: boolean;
}

export function Editor({
  isFocused,
  setIsFocused,
  scrollY,
  setScrollY,
  title,
  setTitle,
  lyrics,
  setLyrics,
  setCursorPosition,
  textareaRef,
  isSyllableColoringEnabled
}: EditorProps) {
  const adjustTextareaHeight = () => {
    if (textareaRef.current) {
      const scrollContainer = textareaRef.current.closest('.overflow-y-auto');
      const currentScrollTop = scrollContainer ? scrollContainer.scrollTop : 0;

      textareaRef.current.style.height = 'auto';
      textareaRef.current.style.height = textareaRef.current.scrollHeight + 'px';

      if (scrollContainer) {
        scrollContainer.scrollTop = currentScrollTop;
      }
    }
  };

  // Auto-resize textarea
  useEffect(() => {
    adjustTextareaHeight();

    window.addEventListener('resize', adjustTextareaHeight);
    if (document.fonts) {
      document.fonts.ready.then(adjustTextareaHeight);
    }

    return () => {
      window.removeEventListener('resize', adjustTextareaHeight);
    };
  }, [lyrics]);

  const handleKeyUp = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    setCursorPosition(e.currentTarget.selectionStart);
  };

  const handleClick = (e: React.MouseEvent<HTMLTextAreaElement>) => {
    setCursorPosition(e.currentTarget.selectionStart);
  };

  const renderColoredLyrics = (text: string) => {
    if (!text) return null;

    // Split by words and non-words to preserve spacing and punctuation
    const parts = text.split(/([a-zA-Z0-9']+)/g);

    return parts.map((part, i) => {
      if (/[a-zA-Z0-9']+/.test(part)) {
        const count = syllable(part);
        let colorClass = 'text-white/90'; // default

        if (isSyllableColoringEnabled) {
          if (count === 1) colorClass = 'text-emerald-300';
          else if (count === 2) colorClass = 'text-blue-300';
          else if (count === 3) colorClass = 'text-purple-300';
          else if (count >= 4) colorClass = 'text-rose-300';
        }

        return <span key={i} className={colorClass}>{part}</span>;
      }
      return <span key={i} className="text-white/90">{part}</span>;
    });
  };

  return (
    <motion.div
      animate={{ paddingTop: isFocused ? '0' : '4rem' }}
      transition={{ duration: 0.5, ease: [0.16, 1, 0.3, 1] }}
      className="flex-1 relative overflow-hidden flex flex-col"
    >
      <div className="absolute inset-0 pointer-events-none bg-gradient-to-b from-indigo-500/5 to-transparent opacity-50" />

      <div
        className="flex-1 overflow-y-auto relative scroll-smooth"
        onScroll={(e) => setScrollY(e.currentTarget.scrollTop)}
      >
        <div className="max-w-3xl mx-auto min-h-full flex flex-col">
          {/* Sticky Title */}
          <div
            className={`sticky top-0 z-10 bg-[#0a0a0a]/90 backdrop-blur-xl transition-all duration-300 px-8 md:px-12 ${
              scrollY > 20
                ? 'py-4 border-b border-white/10 shadow-lg shadow-black/50'
                : 'pt-8 md:pt-12 pb-8 border-b border-transparent'
            }`}
          >
            <input
              type="text"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Song Title..."
              onFocus={() => setIsFocused(true)}
              className={`bg-transparent font-serif font-bold outline-none placeholder:text-white/20 w-full transition-all duration-300 ${
                scrollY > 20 ? 'text-2xl md:text-3xl' : 'text-4xl md:text-5xl'
              }`}
            />
          </div>

          {/* Lyrics Textarea */}
          <div className="px-8 md:px-12 pb-[50vh] md:pb-32 flex-1 flex flex-col">
            <div className="relative w-full flex-1">
              <div
                className={`lyrics-editor lyrics-backdrop w-full min-h-[50vh] ${!isSyllableColoringEnabled ? 'opacity-0' : ''}`}
                aria-hidden="true"
              >
                {!lyrics && <span className="text-white/20">Start writing your lyrics here...</span>}
                {renderColoredLyrics(lyrics)}
                {/* Add a trailing newline space if the text ends with a newline to ensure the cursor can go to the next line visually */}
                {lyrics.endsWith('\n') && <br />}
              </div>
              <textarea
                ref={textareaRef}
                value={lyrics}
                onChange={(e) => {
                  setLyrics(e.target.value);
                  setCursorPosition(e.target.selectionStart);
                }}
                onKeyUp={handleKeyUp}
                onClick={handleClick}
                onFocus={() => setIsFocused(true)}
                placeholder="Start writing your lyrics here..."
                className={`lyrics-editor w-full overflow-hidden min-h-[50vh] ${isSyllableColoringEnabled ? 'lyrics-textarea' : ''}`}
                spellCheck={false}
              />
            </div>
          </div>
        </div>
      </div>
    </motion.div>
  );
}
