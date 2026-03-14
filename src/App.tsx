import React, { useState, useRef, useEffect } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Sparkles, Wand2, AlignLeft, Music, Loader2, ChevronRight, ChevronDown, FolderOpen, Save, Plus, Trash2, X } from 'lucide-react';
import { getRhymeSuggestions } from './services/gemini';
import { syllable } from 'syllable';

import { SongProject } from "./types";
import { Header } from './components/Header';
import { Editor } from './components/Editor';
import { Sidebar } from './components/Sidebar';
import { ProjectsModal } from './components/ProjectsModal';


export default function App() {
  const [theme, setTheme] = useState('');
  const [title, setTitle] = useState(() => localStorage.getItem('lyricist-title') || '');
  const [lyrics, setLyrics] = useState(() => localStorage.getItem('lyricist-lyrics') || '');
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [cursorPosition, setCursorPosition] = useState(0);
  const [isFocused, setIsFocused] = useState(false);
  const [scrollY, setScrollY] = useState(0);
  const [rhymeType, setRhymeType] = useState('Perfect Rhyme');
  const [isContextExpanded, setIsContextExpanded] = useState(false);
  const [isHighlightEnabled, setIsHighlightEnabled] = useState(true);
  const [isSyllableColoringEnabled, setIsSyllableColoringEnabled] = useState(true);
  const [rhymeScheme, setRhymeScheme] = useState('AABB');
  const [customRhymeScheme, setCustomRhymeScheme] = useState('');
  const [projects, setProjects] = useState<SongProject[]>(() => {
    const saved = localStorage.getItem('lyricist-projects');
    return saved ? JSON.parse(saved) : [];
  });
  const [currentProjectId, setCurrentProjectId] = useState<string | null>(() => localStorage.getItem('lyricist-current-project') || null);
  const [isProjectsModalOpen, setIsProjectsModalOpen] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const rhymeOptions = ['Perfect Rhyme', 'Near Rhyme', 'Slant Rhyme'];

  // Save to local storage
  useEffect(() => {
    localStorage.setItem('lyricist-title', title);
    localStorage.setItem('lyricist-lyrics', lyrics);
  }, [title, lyrics]);

  useEffect(() => {
    localStorage.setItem('lyricist-projects', JSON.stringify(projects));
  }, [projects]);

  useEffect(() => {
    if (currentProjectId) {
      localStorage.setItem('lyricist-current-project', currentProjectId);
    } else {
      localStorage.removeItem('lyricist-current-project');
    }
  }, [currentProjectId]);

  // Auto-save current project
  useEffect(() => {
    if (currentProjectId) {
      setProjects(prev => prev.map(p => 
        p.id === currentProjectId 
          ? { ...p, title, lyrics, theme, updatedAt: Date.now() }
          : p
      ));
    }
  }, [title, lyrics, theme, currentProjectId]);

  const handleSaveProject = () => {
    if (!currentProjectId) {
      const newProject: SongProject = {
        id: crypto.randomUUID(),
        title: title || 'Untitled Song',
        lyrics,
        theme,
        updatedAt: Date.now()
      };
      setProjects(prev => [newProject, ...prev]);
      setCurrentProjectId(newProject.id);
    }
  };

  const handleNewProject = () => {
    setTitle('');
    setLyrics('');
    setTheme('');
    setCurrentProjectId(null);
    setIsProjectsModalOpen(false);
  };

  const handleLoadProject = (project: SongProject) => {
    setTitle(project.title);
    setLyrics(project.lyrics);
    setTheme(project.theme);
    setCurrentProjectId(project.id);
    setIsProjectsModalOpen(false);
  };

  const handleDeleteProject = (e: React.MouseEvent, id: string) => {
    e.stopPropagation();
    setProjects(prev => prev.filter(p => p.id !== id));
    if (currentProjectId === id) {
      setCurrentProjectId(null);
    }
  };


  const activeRhymeScheme = rhymeScheme === 'Custom' ? (customRhymeScheme || 'AABB') : rhymeScheme;

  // Extract the current line and stanza based on cursor position
  const getRhymeContext = () => {
    if (!lyrics) return { targetLine: null, currentLetter: activeRhymeScheme[0] || 'A', stanzaLines: [], currentLineIndex: 0 };
    
    const textBeforeCursor = lyrics.substring(0, cursorPosition);
    const textAfterCursor = lyrics.substring(cursorPosition);
    
    // Find stanza boundaries
    const lastDoubleNewline = textBeforeCursor.lastIndexOf('\n\n');
    const stanzaStart = lastDoubleNewline === -1 ? 0 : lastDoubleNewline + 2;
    
    const nextDoubleNewline = textAfterCursor.indexOf('\n\n');
    const stanzaEnd = nextDoubleNewline === -1 ? lyrics.length : cursorPosition + nextDoubleNewline;
    
    const currentStanza = lyrics.substring(stanzaStart, stanzaEnd);
    const stanzaLines = currentStanza.split('\n');
    
    // Calculate which line index we are currently on within the stanza
    const stanzaTextBeforeCursor = textBeforeCursor.substring(stanzaStart);
    const currentLineIndex = stanzaTextBeforeCursor.split('\n').length - 1;
    
    const schemeLetters = activeRhymeScheme.split('');
    if (schemeLetters.length === 0) return { targetLine: null, currentLetter: 'A', stanzaLines, currentLineIndex };
    
    const currentLetter = schemeLetters[currentLineIndex % schemeLetters.length];
    
    // Find the previous line in this stanza that has the same letter
    let targetLine = null;
    for (let i = currentLineIndex - 1; i >= 0; i--) {
      if (schemeLetters[i % schemeLetters.length] === currentLetter) {
        targetLine = stanzaLines[i].trim();
        if (targetLine) break; // found a non-empty line to rhyme with
      }
    }
    
    return { targetLine, currentLetter, stanzaLines, currentLineIndex };
  };

  const handleGetSuggestions = async () => {
    const context = getRhymeContext();
    if (!lyrics) return;

    setIsLoading(true);
    try {
      const results = await getRhymeSuggestions(
        theme, 
        lyrics, 
        context.targetLine, 
        rhymeType, 
        activeRhymeScheme, 
        context.currentLetter
      );
      setSuggestions(results);
    } catch (error) {
      console.error(error);
    } finally {
      setIsLoading(false);
    }
  };

  const insertSuggestion = (suggestion: string) => {
    if (!textareaRef.current) return;
    
    const textBeforeCursor = lyrics.substring(0, cursorPosition);
    const textAfterCursor = lyrics.substring(cursorPosition);
    
    // Determine if we need a newline
    const needsNewline = textBeforeCursor.length > 0 && !textBeforeCursor.endsWith('\n');
    const insertText = (needsNewline ? '\n' : '') + suggestion + '\n';
    
    const newLyrics = textBeforeCursor + insertText + textAfterCursor;
    setLyrics(newLyrics);
    
    // Update cursor position
    const newPosition = cursorPosition + insertText.length;
    setTimeout(() => {
      if (textareaRef.current) {
        textareaRef.current.selectionStart = newPosition;
        textareaRef.current.selectionEnd = newPosition;
        textareaRef.current.focus();
      }
    }, 0);
    
    setSuggestions([]);
  };





  const rhymeContext = getRhymeContext();

  return (
    <div className="min-h-screen bg-[#0a0a0a] text-white overflow-hidden relative flex flex-col md:flex-row">
      {/* Main Editor Area */}
      <main className="flex-1 flex flex-col h-screen relative w-full">
        {/* Header */}
        <Header
          isFocused={isFocused}
          setIsProjectsModalOpen={setIsProjectsModalOpen}
          currentProjectId={currentProjectId}
          handleSaveProject={handleSaveProject}
          lyrics={lyrics}
        />

        {/* Editor */}
        <Editor
          isFocused={isFocused}
          setIsFocused={setIsFocused}
          scrollY={scrollY}
          setScrollY={setScrollY}
          title={title}
          setTitle={setTitle}
          lyrics={lyrics}
          setLyrics={setLyrics}
          setCursorPosition={setCursorPosition}
          textareaRef={textareaRef}
          isSyllableColoringEnabled={isSyllableColoringEnabled}
        />
      </main>

      {/* Sidebar / Assistant */}
      <Sidebar
        isFocused={isFocused}
        isContextExpanded={isContextExpanded}
        setIsContextExpanded={setIsContextExpanded}
        theme={theme}
        setTheme={setTheme}
        rhymeContext={rhymeContext}
        rhymeScheme={rhymeScheme}
        setRhymeScheme={setRhymeScheme}
        customRhymeScheme={customRhymeScheme}
        setCustomRhymeScheme={setCustomRhymeScheme}
        activeRhymeScheme={activeRhymeScheme}
        rhymeType={rhymeType}
        setRhymeType={setRhymeType}
        rhymeOptions={rhymeOptions}
        isHighlightEnabled={isHighlightEnabled}
        setIsHighlightEnabled={setIsHighlightEnabled}
        isSyllableColoringEnabled={isSyllableColoringEnabled}
        setIsSyllableColoringEnabled={setIsSyllableColoringEnabled}
        handleGetSuggestions={handleGetSuggestions}
        isLoading={isLoading}
        suggestions={suggestions}
        insertSuggestion={insertSuggestion}
        lyrics={lyrics}
      />

      {/* Floating button to exit focus mode */}
      <AnimatePresence>
        {isFocused && (
          <motion.button
            initial={{ opacity: 0, y: 20, scale: 0.9 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 20, scale: 0.9 }}
            onClick={() => setIsFocused(false)}
            className="fixed bottom-8 right-8 z-30 bg-indigo-600 hover:bg-indigo-500 text-white px-5 py-3 rounded-full shadow-lg shadow-indigo-500/20 flex items-center gap-2 transition-all cursor-pointer"
          >
            <Wand2 className="w-4 h-4" />
            <span className="font-medium">Show Assistant</span>
          </motion.button>
        )}
      </AnimatePresence>

      {/* Projects Modal */}
      <ProjectsModal
        isProjectsModalOpen={isProjectsModalOpen}
        setIsProjectsModalOpen={setIsProjectsModalOpen}
        projects={projects}
        currentProjectId={currentProjectId}
        handleNewProject={handleNewProject}
        handleLoadProject={handleLoadProject}
        handleDeleteProject={handleDeleteProject}
      />
    </div>
  );
}
