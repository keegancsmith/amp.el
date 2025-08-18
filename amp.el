;;; amp.el --- Minimal Amp IDE integration for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Keegan Carruthers-Smith

;; Author: Keegan Carruthers-Smith <keegan.csmith@gmail.com>
;; Author: Amp <amp@ampcode.com>
;; Version: 0.0.1
;; Package-Requires: ((emacs "28.1") (websocket "1.12") (project "0.8.1"))
;; Keywords: amp, ai, agent, assistant
;; URL: https://github.com/keegancsmith/amp.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Minimal Amp IDE integration for Emacs.
;;
;; This package creates a WebSocket server that Amp CLI can connect to
;; when started with the --jetbrains flag. It provides basic IDE integration
;; including:
;; - File and selection tracking
;; - WebSocket server for Amp communication
;; - Project configuration file management
;;
;; Usage:
;; M-x amp-start-ide-server - Start IDE server for current project
;; M-x amp-stop-ide-server - Stop IDE server for current project
;; M-x amp-ide-status - Show current IDE integration status
;; M-x amp-debug-buffer - View WebSocket communication debug logs

;;; Code:

(require 'websocket)
(require 'json)
(require 'project)
(require 'cl-lib)

;;; Customization

(defgroup amp nil
  "Amp IDE integration for Emacs."
  :group 'tools
  :prefix "amp-")

(defcustom amp-ide-data-dir
  (expand-file-name "amp/ide" (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Directory where Amp IDE config files are stored."
  :type 'directory
  :group 'amp)

;;; Variables

(defvar amp--ide-servers (make-hash-table :test 'equal)
  "Hash table mapping project directories to IDE server info.")

(defvar amp--ide-clients (make-hash-table :test 'equal)
  "Hash table mapping project directories to connected WebSocket clients.")

(defvar amp--selection-timer nil
  "Timer for debounced selection change notifications.")

(defvar amp--selection-delay 0.05
  "Delay in seconds before sending selection changes.")

(defvar amp--last-selection-state nil
  "Last known selection state to avoid unnecessary updates.")

(defconst amp-ide-version "0.0.1"
  "Version of the Amp IDE integration.")

(defvar amp--debug-buffer-name "*Amp IDE Debug*"
  "Name of the debug buffer for WebSocket communication.")

;;; Debug Functions

(defun amp--get-debug-buffer ()
  "Get or create the debug buffer."
  (get-buffer-create amp--debug-buffer-name))

(defun amp--find-project-for-ws (ws)
  "Find the project directory for a given WebSocket connection."
  (catch 'found
    (maphash (lambda (project-dir client)
               (when (eq client ws)
                 (throw 'found project-dir)))
             amp--ide-clients)
    nil))

(defun amp--debug-log (direction project-dir message)
  "Log a WebSocket message to the debug buffer.
DIRECTION should be 'incoming' or 'outgoing'.
PROJECT-DIR is the project directory.
MESSAGE is the WebSocket message (string or object)."
  (let ((buffer (amp--get-debug-buffer))
        (timestamp (format-time-string "%H:%M:%S.%3N"))
        (project-name (file-name-nondirectory (directory-file-name project-dir)))
        (message-str (if (stringp message) message (json-encode message))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format "[%s] %s [%s]: %s\n"
                      timestamp
                      (upcase (symbol-name direction))
                      project-name
                      message-str))
      ;; Keep buffer size reasonable (last 1000 lines)
      (let ((lines (count-lines (point-min) (point-max))))
        (when (> lines 1000)
          (goto-char (point-min))
          (forward-line (- lines 1000))
          (delete-region (point-min) (point)))))))

;;; Utility Functions

(defun amp--get-project-root ()
  "Get the current project root directory."
  (when-let ((project (project-current)))
    (expand-file-name (project-root project))))

(defun amp--generate-auth-token ()
  "Generate a random authentication token."
  (let ((chars "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
    (apply #'string
           (cl-loop repeat 32
                    collect (aref chars (random (length chars)))))))

(defun amp--current-file-uri ()
  "Get the file URI for the current buffer."
  (when buffer-file-name
    (concat "file://" (expand-file-name buffer-file-name))))

(defun amp--current-selection ()
  "Get the current selection in the active buffer."
  (when (use-region-p)
    (let* ((start (region-beginning))
           (end (region-end))
           (start-line (1- (line-number-at-pos start))) ; Convert to 0-based
           (end-line (1- (line-number-at-pos end)))
           (start-char (- start (line-beginning-position)))
           (end-char (- end (line-beginning-position))))
      `((range . ((startLine . ,start-line)
                  (startCharacter . ,start-char)
                  (endLine . ,end-line)
                  (endCharacter . ,end-char)))
        (content . ,(buffer-substring-no-properties start end))))))

;;; WebSocket Server

(defun amp--create-ide-server (project-dir)
  "Create a WebSocket server for PROJECT-DIR."
  (let* ((port 0) ; Let the system assign a port
         (auth-token (amp--generate-auth-token))
         (server (websocket-server
                  port
                  :host "127.0.0.1"
                  :on-open (lambda (ws)
                             (message "Amp IDE client connected to project: %s" project-dir)
                             (amp--debug-log 'incoming project-dir "Client connected")
                             (puthash project-dir ws amp--ide-clients)
                             ;; Send initial metadata and visible files
                             (amp--send-initial-notifications project-dir))
                  :on-message (lambda (ws frame)
                                (amp--handle-message project-dir ws frame))
                  :on-close (lambda (ws)
                              (message "Amp IDE client disconnected from project: %s" project-dir)
                              (amp--debug-log 'incoming project-dir "Client disconnected")
                              (remhash project-dir amp--ide-clients))
                  :on-error (lambda (ws type err)
                              (message "Amp IDE WebSocket error: %s %s" type err)
                              (amp--debug-log 'incoming project-dir
                                              (format "WebSocket error: type=%s err=%s" type err))))))
    ;; Get the actual assigned port
    (let ((actual-port (process-contact server :service)))
      (message "Amp IDE WebSocket server created on port %d for project: %s" actual-port project-dir)
      ;; Store server info
      (puthash project-dir
               `((server . ,server)
                 (port . ,actual-port)
                 (authToken . ,auth-token)
                 (project-dir . ,project-dir))
               amp--ide-servers)
      ;; Write config file for Amp CLI discovery
      (amp--write-config-file project-dir actual-port auth-token)
      actual-port)))

(defun amp--handle-message (project-dir ws frame)
  "Handle a WebSocket message from Amp CLI."
  (condition-case err
      (let* ((message-text (websocket-frame-text frame))
             (message (json-read-from-string message-text))
             (client-request (cdr (assq 'clientRequest message))))
        ;; Debug log incoming message
        (amp--debug-log 'incoming project-dir message-text)
        (when client-request
          (amp--handle-client-request project-dir ws client-request)))
    (error
     (message "Error handling Amp IDE message: %s" (error-message-string err)))))

(defun amp--handle-client-request (project-dir ws request)
  "Handle a client request from Amp CLI."
  (let ((id (cdr (assq 'id request)))
        (authenticate (cdr (assq 'authenticate request)))
        (ping (cdr (assq 'ping request)))
        (server-info (gethash project-dir amp--ide-servers)))
    (cond
     ;; Authentication request
     (authenticate
      (let* ((provided-token (cdr (assq 'authToken authenticate)))
             (expected-token (cdr (assq 'authToken server-info)))
             (authenticated (string= provided-token expected-token)))
        (amp--send-response ws id `((authenticate . ((authenticated . ,authenticated)))))))
     ;; Ping request
     (ping
      (let ((ping-message (cdr (assq 'message ping))))
        (amp--send-response ws id `((ping . ((message . ,ping-message)))))))
     ;; Unknown request
     (t
      (amp--send-error ws id 400 "Unknown request method")))))

(defun amp--send-response (ws id response-data)
  "Send a response to the WebSocket client."
  (let* ((response `((serverResponse . ((id . ,id) ,@response-data))))
         (response-text (json-encode response)))
    ;; Debug log outgoing response
    (when-let ((project-dir (amp--find-project-for-ws ws)))
      (amp--debug-log 'outgoing project-dir response-text))
    (websocket-send-text ws response-text)))

(defun amp--send-error (ws id code message)
  "Send an error response to the WebSocket client."
  (let* ((response `((serverResponse . ((id . ,id)
                                        (error . ((code . ,code)
                                                  (message . ,message)))))))
         (response-text (json-encode response)))
    ;; Debug log outgoing error
    (when-let ((project-dir (amp--find-project-for-ws ws)))
      (amp--debug-log 'outgoing project-dir response-text))
    (websocket-send-text ws response-text)))

(defun amp--send-notification (project-dir notification)
  "Send a notification to the connected Amp CLI client."
  (when-let ((client (gethash project-dir amp--ide-clients)))
    (let* ((message `((serverNotification . ,notification)))
           (message-text (json-encode message)))
      ;; Debug log outgoing notification
      (amp--debug-log 'outgoing project-dir message-text)
      (websocket-send-text client message-text))))

;;; File and Selection Tracking

(defun amp--send-initial-notifications (project-dir)
  "Send initial notifications after client connection."
  ;; Send plugin metadata
  (amp--send-notification
   project-dir
   `((pluginMetadata . ((version . ,amp-ide-version)))))
  ;; Send current visible files
  (amp--track-visible-files-change))

(defun amp--track-selection-change ()
  "Track and send selection changes to Amp with debouncing."
  (let ((current-state (list (amp--current-file-uri) (use-region-p) (when (use-region-p) (region-beginning)) (when (use-region-p) (region-end)))))
    (unless (equal current-state amp--last-selection-state)
      (setq amp--last-selection-state current-state)
      (when amp--selection-timer
        (cancel-timer amp--selection-timer))
      (setq amp--selection-timer
            (run-at-time amp--selection-delay nil #'amp--send-selection-update)))))

(defun amp--send-selection-update ()
  "Send the current selection state to Amp."
  (when-let* ((project-dir (amp--get-project-root))
              (uri (amp--current-file-uri)))
    (let ((selections (if (use-region-p)
                          (list (amp--current-selection))
                        '())))
      (amp--send-notification
       project-dir
       `((selectionDidChange . ((uri . ,uri)
                                (selections . ,(vconcat selections)))))))))

(defun amp--track-visible-files-change ()
  "Track and send visible files changes to Amp."
  (when-let ((project-dir (amp--get-project-root)))
    (let ((visible-uris (cl-remove-if-not
                         #'identity
                         (mapcar (lambda (buf)
                                   (with-current-buffer buf
                                     (amp--current-file-uri)))
                                 (cl-remove-if-not #'buffer-file-name (buffer-list))))))
      (when visible-uris
        (amp--send-notification
         project-dir
         `((visibleFilesDidChange . ((uris . ,(vconcat visible-uris))))))))))

;;; Config File Management

(defun amp--write-config-file (project-dir port auth-token)
  "Write the project config file for Amp CLI discovery."
  (let* ((config-dir amp-ide-data-dir)
         (config-file (expand-file-name (format "%d.json" port) config-dir))
         (config `((workspaceFolders . ,(vector project-dir))
                   (port . ,port)
                   (ideName . "Emacs")
                   (authToken . ,auth-token)
                   (pid . ,(emacs-pid)))))
    ;; Ensure directory exists
    (make-directory config-dir t)
    ;; Write config file
    (with-temp-file config-file
      (insert (json-encode config)))
    (message "Amp IDE config written to: %s" config-file)))

(defun amp--remove-config-file (project-dir)
  "Remove the config file for PROJECT-DIR."
  (when-let* ((server-info (gethash project-dir amp--ide-servers))
              (port (cdr (assq 'port server-info)))
              (config-file (expand-file-name (format "%d.json" port) amp-ide-data-dir)))
    (when (file-exists-p config-file)
      (delete-file config-file)
      (message "Amp IDE config file removed: %s" config-file))))

;;; Commands

;;;###autoload
(defun amp-start-ide-server ()
  "Start Amp IDE server for the current project."
  (interactive)
  (let ((project-dir (amp--get-project-root)))
    (unless project-dir
      (user-error "Not in a project directory"))

    (if (gethash project-dir amp--ide-servers)
        (message "Amp IDE server already running for project: %s" project-dir)
      (let ((port (amp--create-ide-server project-dir)))
        (message "Amp IDE server started on port %d for project: %s" port project-dir)
        ;; Start tracking file/selection changes
        (add-hook 'post-command-hook #'amp--track-selection-change)
        (add-hook 'buffer-list-update-hook #'amp--track-visible-files-change)))))

;;;###autoload
(defun amp-stop-ide-server ()
  "Stop Amp IDE server for the current project."
  (interactive)
  (let ((project-dir (amp--get-project-root)))
    (unless project-dir
      (user-error "Not in a project directory"))

    (if-let ((server-info (gethash project-dir amp--ide-servers)))
        (progn
          ;; Close WebSocket server
          (websocket-server-close (cdr (assq 'server server-info)))
          ;; Remove config file
          (amp--remove-config-file project-dir)
          ;; Clean up data structures
          (remhash project-dir amp--ide-servers)
          (remhash project-dir amp--ide-clients)
          ;; Remove hooks if no servers are running
          (unless (hash-table-count amp--ide-servers)
            (remove-hook 'post-command-hook #'amp--track-selection-change)
            (remove-hook 'buffer-list-update-hook #'amp--track-visible-files-change))
          (message "Amp IDE server stopped for project: %s" project-dir))
      (message "No Amp IDE server running for project: %s" project-dir))))

;;;###autoload
(defun amp-ide-status ()
  "Show Amp IDE integration status."
  (interactive)
  (if (= 0 (hash-table-count amp--ide-servers))
      (message "No Amp IDE servers running")
    (let ((status-lines '("Amp IDE servers:")))
      (maphash (lambda (project-dir server-info)
                 (let ((port (cdr (assq 'port server-info)))
                       (connected (gethash project-dir amp--ide-clients)))
                   (push (format "  %s: port %d (%s)"
                                 (file-name-nondirectory (directory-file-name project-dir))
                                 port
                                 (if connected "connected" "waiting"))
                         status-lines)))
               amp--ide-servers)
      (message "%s" (string-join (reverse status-lines) "\n")))))

;;;###autoload
(defun amp-debug-buffer ()
  "Open the Amp IDE debug buffer to view WebSocket communication."
  (interactive)
  (switch-to-buffer (amp--get-debug-buffer)))

;;; Cleanup and Setup

(defun amp--stop-all-servers ()
  "Stop all Amp IDE servers and clean up."
  (maphash (lambda (project-dir server-info)
             (websocket-server-close (cdr (assq 'server server-info)))
             (amp--remove-config-file project-dir))
           amp--ide-servers)
  (clrhash amp--ide-servers)
  (clrhash amp--ide-clients)
  (when amp--selection-timer
    (cancel-timer amp--selection-timer)
    (setq amp--selection-timer nil))
  (setq amp--last-selection-state nil))

;; Clean up on Emacs exit
(add-hook 'kill-emacs-hook #'amp--stop-all-servers)

;;;###autoload
(defun amp-ide-setup ()
  "Set up Amp IDE integration."
  (interactive)
  (message "Amp IDE integration loaded. Use M-x amp-start-ide-server to begin."))

(provide 'amp)

;;; amp.el ends here
