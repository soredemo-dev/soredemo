import { contextBridge, ipcRenderer } from 'electron';

// Sandboxed, context-isolated preload. Exposes ONLY the minimal shell API to the
// renderer — no Node, no filesystem, no engine access. Everything else the page
// needs it obtains from the loopback Studio HTTP server over its authenticated
// session, exactly as the browser flow does.
contextBridge.exposeInMainWorld('soredemoDesktop', {
  getAppVersion: (): Promise<string> => ipcRenderer.invoke('soredemo:getAppVersion'),
  pickProjectDirectory: (): Promise<string | null> =>
    ipcRenderer.invoke('soredemo:pickProjectDirectory'),
});
