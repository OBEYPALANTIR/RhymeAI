import React from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Music, FolderOpen, Plus, Trash2, X } from 'lucide-react';
import { SongProject } from '../types';

interface ProjectsModalProps {
  isProjectsModalOpen: boolean;
  setIsProjectsModalOpen: (open: boolean) => void;
  projects: SongProject[];
  currentProjectId: string | null;
  handleNewProject: () => void;
  handleLoadProject: (project: SongProject) => void;
  handleDeleteProject: (e: React.MouseEvent, id: string) => void;
}

export function ProjectsModal({
  isProjectsModalOpen,
  setIsProjectsModalOpen,
  projects,
  currentProjectId,
  handleNewProject,
  handleLoadProject,
  handleDeleteProject
}: ProjectsModalProps) {
  return (
    <AnimatePresence>
      {isProjectsModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            onClick={() => setIsProjectsModalOpen(false)}
            className="absolute inset-0 bg-black/60 backdrop-blur-sm"
          />
          <motion.div
            initial={{ opacity: 0, scale: 0.95, y: 20 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.95, y: 20 }}
            className="relative w-full max-w-2xl bg-[#111] border border-white/10 rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[80vh]"
          >
            <div className="p-6 border-b border-white/10 flex items-center justify-between shrink-0">
              <h2 className="text-xl font-medium flex items-center gap-2">
                <FolderOpen className="w-5 h-5 text-indigo-400" />
                Song Projects
              </h2>
              <button
                onClick={() => setIsProjectsModalOpen(false)}
                className="p-2 hover:bg-white/10 rounded-full transition-colors cursor-pointer"
              >
                <X className="w-5 h-5 text-white/50 hover:text-white" />
              </button>
            </div>

            <div className="p-6 overflow-y-auto flex-1">
              <button
                onClick={handleNewProject}
                className="w-full mb-6 py-4 border-2 border-dashed border-white/20 hover:border-indigo-500/50 hover:bg-indigo-500/5 rounded-xl flex items-center justify-center gap-2 text-white/70 hover:text-white transition-all cursor-pointer"
              >
                <Plus className="w-5 h-5" />
                Create New Song
              </button>

              {projects.length === 0 ? (
                <div className="text-center py-12 text-white/30">
                  <Music className="w-12 h-12 mx-auto mb-4 opacity-20" />
                  <p>No saved songs yet.</p>
                </div>
              ) : (
                <div className="grid gap-4">
                  {projects.sort((a, b) => b.updatedAt - a.updatedAt).map(project => (
                    <div
                      key={project.id}
                      onClick={() => handleLoadProject(project)}
                      className={`p-4 rounded-xl border transition-all cursor-pointer group flex items-center justify-between ${
                        currentProjectId === project.id
                          ? 'bg-indigo-600/10 border-indigo-500/50'
                          : 'bg-white/5 border-white/5 hover:border-white/20 hover:bg-white/10'
                      }`}
                    >
                      <div className="min-w-0 flex-1 pr-4">
                        <h3 className="font-medium text-white truncate">
                          {project.title || 'Untitled Song'}
                        </h3>
                        <p className="text-sm text-white/40 truncate mt-1">
                          {new Date(project.updatedAt).toLocaleDateString()} • {project.lyrics.split(/\s+/).filter(w => w.length > 0).length} words
                        </p>
                      </div>
                      <button
                        onClick={(e) => handleDeleteProject(e, project.id)}
                        className="p-2 text-white/20 hover:text-red-400 hover:bg-red-400/10 rounded-lg transition-colors opacity-0 group-hover:opacity-100 cursor-pointer"
                        title="Delete Project"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </motion.div>
        </div>
      )}
    </AnimatePresence>
  );
}
