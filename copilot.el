;;; copilot.el --- An Emacs plugin for GitHub Copilot -*- lexical-binding: t; -*-

;; Copyright (C) 2022-2026 copilot-emacs maintainers

;; Author: zerol <z@zerol.me>
;; Maintainer: Bozhidar Batsov <bozhidar@batsov.dev>
;; URL: https://github.com/copilot-emacs/copilot.el
;; Package-Requires: ((emacs "27.2") (editorconfig "0.8.2") (jsonrpc "1.0.14") (compat "30") (track-changes "1.4"))
;; Version: 0.5.0
;; Keywords: convenience copilot

;; The MIT License (MIT)

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; An Emacs plugin for GitHub Copilot

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'compile)
(require 'json)
(require 'jsonrpc)
(require 'subr-x)
(require 'auth-source)
(require 'url-parse)

(require 'editorconfig)
(require 'track-changes)

(require 'copilot-balancer)

(defgroup copilot nil
  "Copilot."
  :group 'completion
  :prefix "copilot-")

(defcustom copilot-idle-delay 0
  "Time in seconds to wait before starting completion.

Complete immediately if set to 0.
Disable idle completion if set to nil."
  :type '(choice
          (number :tag "Seconds of delay")
          (const :tag "Idle completion disabled" nil))
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defcustom copilot-completion-timeout 30
  "Timeout in seconds for completion requests.
Cloud models like Gemini may need a longer timeout."
  :type 'number
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-network-proxy nil
  "Network proxy to use for Copilot.

Nil means no proxy.
Format: \='(:host \"127.0.0.1\" :port 80 :username \"username\"
            :password \"password\")
Username and password are optional.

If you are using a MITM proxy which intercepts TLS connections, you may need
to disable TLS verification.  This can be done by setting a pair
':rejectUnauthorized :json-false' in the proxy plist.  For example:

  (:host \"127.0.0.1\" :port 80 :rejectUnauthorized :json-false)"
  :type '(plist :tag "Uncheck all to disable proxy" :key-type symbol)
  :options '((:host string) (:port integer) (:username string) (:password string))
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defcustom copilot-log-max 0
  "Max size of the `*copilot events*' jsonrpc events buffer.
This buffer records all JSON-RPC traffic between Emacs and the Copilot
language server, which is useful for debugging protocol-level issues.
Set to a positive integer (e.g. 1000) to enable, 0 to disable, or nil
for unlimited size.  Enabling event logging may slightly affect
performance."
  :group 'copilot
  :type 'integer
  :package-version '(copilot . "0.1"))

(defcustom copilot-server-args '("--stdio")
  "Additional arguments to pass to the Copilot server."
  :group 'copilot
  :type '(repeat string)
  :package-version '(copilot . "0.1"))

(defcustom copilot-max-char 100000
  "Maximum number of characters to send to Copilot, -1 means no limit."
  :group 'copilot
  :type 'integer
  :package-version '(copilot . "0.1"))


(defcustom copilot-clear-overlay-ignore-commands nil
  "List of commands that should not clear the overlay when called."
  :group 'copilot
  :type '(repeat function)
  :package-version '(copilot . "0.1"))

(defconst copilot--hardcoded-clear-overlay-ignore-commands
  '(universal-argument digit-argument negative-argument universal-argument-more)
  "Hardcoded list of commands that should not clear the overlay.")

(defcustom copilot-clear-overlay-on-commands '(beginning-of-visual-line)
  "Commands that must clear the Copilot overlay before execution."
  :group 'copilot
  :type '(repeat function)
  :package-version '(copilot . "0.4"))

(defcustom copilot-indent-offset-warning-disable nil
  "Disable indentation warnings.

Warning occurs when the function `copilot--infer-indentation-offset' cannot
find indentation offset."
  :group 'copilot
  :type 'boolean
  :package-version '(copilot . "0.1"))

(defcustom copilot-max-char-warning-disable nil
  "When non-nil, disable warning about buffer size exceeding `copilot-max-char'."
  :group 'copilot
  :type 'boolean
  :package-version '(copilot . "0.1"))

(defcustom copilot-enable-parentheses-balancer t
  "Whether to post-process completions to balance parentheses in Lisp modes.
When non-nil, completions in Lisp modes are adjusted to ensure that
parentheses remain balanced within the surrounding top-level form.
Set to nil to use completions from the server verbatim."
  :type 'boolean
  :group 'copilot
  :package-version '(copilot . "0.4"))

(defcustom copilot-indentation-alist
  (append '((emacs-lisp-mode lisp-indent-offset)
            (latex-mode tex-indent-basic)
            (lisp-mode lisp-indent-offset)
            (nxml-mode nxml-child-indent)
            (python-mode python-indent py-indent-offset python-indent-offset)
            (python-ts-mode python-indent py-indent-offset python-indent-offset)
            (web-mode web-mode-markup-indent-offset web-mode-html-offset))
          editorconfig-indentation-alist)
  "Alist of `major-mode' to indentation map with optional fallbacks."
  :type '(alist :key-type symbol :value-type (choice integer symbol))
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defcustom copilot-llm-ls-executable "llm-ls"
  "Path to the llm-ls server executable."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-backend "ollama"
  "LLM backend type.
Options: ollama, openai, huggingface, tgi, llamacpp, llm-crate."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-model "qwen2.5-coder:7b"
  "Model name/identifier for the chosen backend."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-backend-url "http://localhost:11434"
  "Backend API URL."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-provider nil
  "Provider name when using llm-crate backend."
  :type '(choice (const nil) string)
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-context-window 32768
  "Context window size in tokens."
  :type 'integer
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-request-body '(:raw t
                                       :options (:temperature 0.2
                                                              :top_p 0.2
                                                              :num_predict 256
                                                              :stop ["<|endoftext|>"
                                                                     "<|fim_prefix|>"
                                                                     "<|fim_middle|>"
                                                                     "<|fim_suffix|>"
                                                                     "<|fim_pad|>"
                                                                     "<|im_start|>"
                                                                     "<|im_end|>"]))
  "Generation parameters passed to the backend."
  :type 'plist
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-fim-enabled t
  "Whether to use fill-in-middle mode."
  :type 'boolean
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-fim-prefix "<|fim_prefix|>"
  "FIM prefix token."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-fim-middle "<|fim_middle|>"
  "FIM middle token."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-fim-suffix "<|fim_suffix|>"
  "FIM suffix token."
  :type 'string
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-tokenizer-config nil
  "Tokenizer configuration.
Nil for default, or plist with :path, :repository, or :url."
  :type '(choice (const nil) plist)
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defcustom copilot-tokens-to-clear '("<|endoftext|>" "<|fim_pad|>")
  "Tokens to strip from completion output."
  :type '(repeat string)
  :group 'copilot
  :package-version '(copilot . "0.5"))

(setq copilot-model-presets
      '(
        (ollama-qwen2.5-coder
         . (:backend "ollama"
                     :model "qwen2.5-coder:7b"
                     :url "http://localhost:11434"
                     :fim-enabled t
                     :fim-prefix "<|fim_prefix|>"
                     :fim-middle "<|fim_middle|>"
                     :fim-suffix "<|fim_suffix|>"
                     :context-window 32768
                     :tokens-to-clear ("<|endoftext|>" "<|fim_pad|>")
                     :request-body (:raw t
                                         :options (:temperature 0.2
                                                                :top_p 0.2
                                                                :num_predict 256
                                                                :stop ["<|endoftext|>"
                                                                       "<|fim_prefix|>"
                                                                       "<|fim_middle|>"
                                                                       "<|fim_suffix|>"
                                                                       "<|fim_pad|>"
                                                                       "<|im_start|>"
                                                                       "<|im_end|>"]))))

        (gemini-3.1-flash-lite-preview
         . (:backend "llm-crate"
                     :provider "google"
                     :model "gemini-3.1-flash-lite-preview"
                     :auth-source-host "llm.gemini"
                     :fim-enabled nil
                     :context-window 32768
                     :request-body (:max_new_tokens 256 :temperature 0.3)))
        ))

(defun copilot--lsp-settings-changed (symbol value)
  "Notify the Copilot LSP that SYMBOL changed to VALUE.

This function will be called by the customization framework when the
`copilot-lsp-settings' is changed.  When changed with `setq', then this function
will not be called."
  (let ((was-bound (boundp symbol)))
    (set-default symbol value)
    (when (and was-bound (copilot--connection-alivep))
      (copilot--notify 'workspace/didChangeConfiguration
                       `(:settings ,(copilot--effective-lsp-settings))))))

(defcustom copilot-lsp-settings nil
  "Settings for the llm-ls LSP server.

This value will always be sent to the server when the server starts or the value
changes.

To change the value of this variable, the customization framework provided by
Emacs must be used.  Either use `setopt' or `customize' to change the value.  If
the value was set without the customization mechanism, then the LSP has to be
manually restarted with `copilot-diagnose'.  Otherwise, the change will not be
applied."
  :set #'copilot--lsp-settings-changed
  :type 'sexp
  :group 'copilot
  :package-version '(copilot . "0.2"))

;; copilot-completion-model removed — replaced by copilot-model defcustom

(defvar-local copilot--overlay nil
  "Overlay for Copilot completion.")

(defvar-local copilot--keymap-overlay nil
  "Overlay used to surround point and make copilot-completion-keymap activate.")

(defvar copilot--connection nil
  "Copilot server jsonrpc connection instance.")

(defvar-local copilot--line-bias 1
  "Line bias for Copilot completion.")

(defvar copilot--post-command-timer nil)
(defvar-local copilot--last-doc-version 0
  "The document version of the last completion.")
(defvar-local copilot--doc-version 0
  "The document version of the current buffer.
Incremented after each change.")

;;
;; Utility functions
;;

(defun copilot--buffer-changed ()
  "Return non-nil if the buffer has changed since last completion."
  (not (= copilot--last-doc-version copilot--doc-version)))

(defvar copilot--opened-buffers nil
  "List of buffers that have been opened in Copilot.")

(defvar copilot--workspace-folders nil
  "List of workspace folder URIs already reported to the server.")

(defvar copilot--status nil
  "Current server status from `didChangeStatus' notification.
Plist with keys :kind, :busy, and :message.")

(defvar copilot--progress-sessions (make-hash-table :test 'equal)
  "Hash table of active progress sessions, keyed by token.
Each value is a plist with :title, :message, and :percentage.")

(defun copilot--progress-lighter ()
  "Compute mode-line progress indicator from active sessions.
Returns nil when no active sessions.  Otherwise returns a string
like \"[title: message]\" or \"[title: 42%]\" from the most
recently updated session."
  (when (> (hash-table-count copilot--progress-sessions) 0)
    (let (latest)
      (maphash (lambda (_k v) (setq latest v)) copilot--progress-sessions)
      (let ((title (plist-get latest :title))
            (message (plist-get latest :message))
            (percentage (plist-get latest :percentage)))
        (cond
         ((stringp message) (format " [%s: %s]" title message))
         ((numberp percentage) (format " [%s: %d%%]" title percentage))
         (t (format " [%s]" title)))))))

(defun copilot--status-lighter ()
  "Compute the mode-line lighter string from `copilot--status'."
  (let ((kind (plist-get copilot--status :kind))
        (busy (plist-get copilot--status :busy))
        (progress (copilot--progress-lighter)))
    (concat
     (cond
      ((or (null kind) (and (equal kind "Normal") (not busy)))
       " Copilot")
      ((and (equal kind "Normal") busy)
       " Copilot*")
      ((equal kind "Warning")
       (propertize " Copilot:Warning" 'face 'warning))
      ((equal kind "Error")
       (propertize " Copilot:Error" 'face 'error))
      ((equal kind "Inactive")
       (propertize " Copilot:Inactive" 'face 'shadow))
      (t " Copilot"))
     progress)))

(defmacro copilot--dbind (pattern source &rest body)
  "Destructure SOURCE against plist PATTERN and eval BODY."
  (declare (indent 2))
  `(cl-destructuring-bind (&key ,@pattern &allow-other-keys) ,source
     ,@body))

(defun copilot--log (level format &rest args)
  "Log message with LEVEL, FORMAT and ARGS."
  (message "%s: %s" (propertize "Copilot" 'face
                                (pcase level
                                  ('error 'error)
                                  ('warning 'warning)
                                  ('info 'success)
                                  (_ 'warning)))
           (apply #'format format args)))

(defun copilot--mode-symbol (mode-name)
  "Infer the language for MODE-NAME."
  (thread-last
    mode-name
    (string-remove-suffix "-ts-mode")
    (string-remove-suffix "-mode")))

(defun copilot--string-common-prefix (str1 str2)
  "Find the common prefix of STR1 and STR2 directly."
  (let ((min-len (min (length str1) (length str2)))
        (i 0))
    (while (and (< i min-len)
                (= (aref str1 i) (aref str2 i)))
      (setq i (1+ i)))
    (substring str1 0 i)))

;;
;; Externals
;;

(declare-function vterm-delete-region "ext:vterm.el")
(declare-function vterm-insert "ext:vterm.el")
(declare-function org-sort-entries "ext:org.el")
(declare-function org-entry-get "ext:org.el")
(declare-function org-map-entries "ext:org.el")

;;
;;; Copilot Server Installation
;;

(defun copilot-installed-version ()
  "Return llm-ls version string when available."
  (when-let* ((exe (ignore-errors (copilot-server-executable)))
              (version-output (with-temp-buffer
                                (when (zerop (call-process exe nil t nil "--version"))
                                  (buffer-string)))))
    (string-trim version-output)))

(defun copilot-server-executable ()
  "Return the location of the configured llm-ls executable."
  (cond
   ((and (file-name-absolute-p copilot-llm-ls-executable)
         (file-exists-p copilot-llm-ls-executable))
    copilot-llm-ls-executable)
   ((executable-find copilot-llm-ls-executable t))
   (t (error "Unable to find llm-ls executable: %s" copilot-llm-ls-executable))))

;; XXX: This function is modified from `lsp-mode'; see `lsp-async-start-process'
;; function for more information.
(defun copilot-async-start-process (callback error-callback &rest command)
  "Start async process COMMAND with CALLBACK and ERROR-CALLBACK."
  (with-current-buffer
      (compilation-start
       (mapconcat
        #'shell-quote-argument
        (seq-filter (lambda (cmd) cmd) command)
        " ")
       t
       (lambda (&rest _)
         (generate-new-buffer-name "*copilot-install-server*")))
    (view-mode +1)
    (add-hook
     'compilation-finish-functions
     (lambda (_buf status)
       (if (string= "finished\n" status)
           (when callback
             (condition-case err
                 (funcall callback)
               (error
                (funcall error-callback (error-message-string err)))))
         (when error-callback
           (funcall error-callback (string-trim-right status)))))
     nil t)))

;;;###autoload
(defun copilot-install-server ()
  "Deprecated installer entrypoint retained for compatibility."
  (interactive)
  (user-error "Server installation is no longer managed by copilot.el; install llm-ls and set `copilot-llm-ls-executable`"))

;;;###autoload
(defun copilot-uninstall-server ()
  "Deprecated uninstaller entrypoint retained for compatibility."
  (interactive)
  (user-error "Server uninstall is no longer managed by copilot.el"))

;;;###autoload
(defun copilot-reinstall-server ()
  "Deprecated reinstaller entrypoint retained for compatibility."
  (interactive)
  (user-error "Server reinstall is no longer managed by copilot.el"))

;;
;; Interaction with Copilot Server
;;

(defconst copilot--ignore-response
  (lambda (_))
  "Simply ignore the response.")

(defun copilot--connection-alivep ()
  "Non-nil if the `copilot--connection' is alive."
  (and copilot--connection
       (zerop (process-exit-status (jsonrpc--process copilot--connection)))))

(defmacro copilot--request (method &optional params &rest args)
  "Send a request to the copilot server for METHOD with PARAMS and ARGS.
When PARAMS is nil, send an empty JSON object so the server does not
reject the request with a schema-validation error."
  `(progn
     (unless (copilot--connection-alivep)
       (copilot--start-server))
     (jsonrpc-request copilot--connection ,method (or ,params (make-hash-table)) ,@args)))

(defmacro copilot--notify (&rest args)
  "Send a notification to the copilot server with ARGS."
  `(progn
     (unless (copilot--connection-alivep)
       (copilot--start-server))
     (jsonrpc-notify copilot--connection ,@args)))

(cl-defmacro copilot--async-request (method params &rest args
                                            &key
                                            (success-fn #'copilot--ignore-response)
                                            (error-fn nil error-fn-supplied-p)
                                            &allow-other-keys)
  "Send an asynchronous request to the copilot server.

Arguments METHOD, PARAMS and ARGS are used in function `jsonrpc-async-request'.

SUCCESS-FN is the CALLBACK.

ERROR-FN is called when the request fails.  When omitted, a default
handler logs the error to *Messages* via `copilot--log'.

Returns the request ID (a number) so callers can cancel the request later."
  (let ((filtered-args (cl-loop for (k v) on args by #'cddr
                                unless (eq k :error-fn)
                                append (list k v))))
    `(progn
       (unless (copilot--connection-alivep)
         (copilot--start-server))
       ;; jsonrpc will use temp buffer for callbacks, so we need to save the
       ;; current buffer and restore it inside callback
       (let ((buf (current-buffer)))
         (car (jsonrpc--async-request-1 copilot--connection
                                        ,method ,params
                                        :success-fn (lambda (result)
                                                      (if (buffer-live-p buf)
                                                          (with-current-buffer buf
                                                            (funcall ,success-fn result))))
                                        :error-fn ,(if error-fn-supplied-p
                                                       error-fn
                                                     `(lambda (err)
                                                        (copilot--log 'error "%s failed: %S"
                                                                      ,method err)))
                                        ,@filtered-args))))))

(defun copilot--shutdown-server ()
  "Shut down the Copilot server with the standard LSP shutdown sequence.
Sends a `shutdown' request followed by an `exit' notification, then
cleans up the connection and resets global state.  Safe to call when
there is no active connection."
  (when copilot--connection
    (condition-case _err
        (jsonrpc-request copilot--connection 'shutdown (make-hash-table) :timeout 3)
      (error nil))
    (condition-case _err
        (jsonrpc-notify copilot--connection 'exit (make-hash-table))
      (error nil))
    (jsonrpc-shutdown copilot--connection)
    (setq copilot--connection nil)
    (setq copilot--opened-buffers nil)
    (setq copilot--workspace-folders nil)
    (setq copilot--status nil)))

(defun copilot--command ()
  "Return the command-line to start copilot server."
  (append
   (list (copilot-server-executable))
   copilot-server-args))

(defun copilot--make-connection ()
  "Establish copilot jsonrpc connection."
  (let ((make-fn (apply-partially
                  #'make-instance
                  'jsonrpc-process-connection
                  :name "copilot"
                  :request-dispatcher #'copilot--handle-request
                  :notification-dispatcher #'copilot--handle-notification
                  :process (make-process :name "copilot server"
                                         :command (copilot--command)
                                         :coding 'utf-8-emacs-unix
                                         :connection-type 'pipe
                                         :stderr (get-buffer-create "*copilot stderr*")
                                         :noquery t))))
    (condition-case nil
        (funcall make-fn :events-buffer-config `(:size ,copilot-log-max))
      (invalid-slot-name
       ;; handle older jsonrpc versions
       (funcall make-fn :events-buffer-scrollback-size copilot-log-max)))))

(defun copilot--effective-lsp-settings ()
  "Return the effective LSP settings."
  (or copilot-lsp-settings (make-hash-table)))

(defun copilot--start-server ()
  "Start the copilot server process in local."
  (cond
   ((not (copilot-server-executable))
    (user-error "Unable to start llm-ls, configure `copilot-llm-ls-executable`"))
   (t
    (setq copilot--connection (copilot--make-connection))
    (setq copilot--workspace-folders nil)
    (copilot--log 'info "Copilot server started.")
    (let* ((root (copilot--workspace-root))
           (root-uri (when root (copilot--path-to-uri root)))
           (folders (when root-uri
                      (setq copilot--workspace-folders (list root-uri))
                      (vector (list :uri root-uri :name (file-name-nondirectory (directory-file-name root)))))))
      (copilot--request
       'initialize
       `(:processId
         ,(emacs-pid)
         ,@(when root-uri `(:rootUri ,root-uri))
         :capabilities
         (:workspace
          (:workspaceFolders t)
          :textDocument
          (:inlineCompletion
           (:dynamicRegistration :json-false)))
         ,@(when folders `(:workspaceFolders ,folders))
         :initializationOptions
         (:editorInfo
          (:name "Emacs" :version ,emacs-version)
          :editorPluginInfo
          (:name "copilot.el" :version ,(or (package-get-version) "unknown"))))))
    (copilot--notify 'initialized (make-hash-table))
    (copilot--notify 'workspace/didChangeConfiguration `(:settings ,(copilot--effective-lsp-settings)))
    (add-hook 'kill-emacs-hook #'copilot--shutdown-server))))

;;
;; login / logout
;;

(defun copilot-select-preset (name)
  "Apply model preset NAME."
  (interactive
   (list (intern (completing-read "Preset: " (mapcar #'car copilot-model-presets)))))
  (let ((preset (alist-get name copilot-model-presets)))
    (unless preset
      (user-error "Unknown preset: %s" name))
    (setq copilot-backend (plist-get preset :backend)
          copilot-model (plist-get preset :model)
          copilot-backend-url (or (plist-get preset :url) copilot-backend-url)
          copilot-provider (plist-get preset :provider)
          copilot-fim-enabled (plist-get preset :fim-enabled)
          copilot-fim-prefix (or (plist-get preset :fim-prefix) copilot-fim-prefix)
          copilot-fim-middle (or (plist-get preset :fim-middle) copilot-fim-middle)
          copilot-fim-suffix (or (plist-get preset :fim-suffix) copilot-fim-suffix)
          copilot-context-window (or (plist-get preset :context-window) copilot-context-window)
          copilot-tokens-to-clear (or (plist-get preset :tokens-to-clear) copilot-tokens-to-clear)
          copilot-auth-source-host (plist-get preset :auth-source-host)
          copilot-request-body (or (plist-get preset :request-body) copilot-request-body))
    (message "Copilot preset applied: %s (model: %s, backend: %s)"
             name copilot-model copilot-backend)))

(defcustom copilot-auth-source-host nil
  "Override auth-source host for API key lookup.
When non-nil, used instead of the auto-derived host."
  :type '(choice (const nil) string)
  :group 'copilot
  :package-version '(copilot . "0.5"))

(defun copilot--provider-host ()
  "Return auth-source host for the current backend."
  (or copilot-auth-source-host
      (pcase copilot-backend
        ("llm-crate" copilot-provider)
        (_ (url-host (url-generic-parse-url copilot-backend-url))))))

(defun copilot--get-api-key ()
  "Retrieve API key from auth-source for the active provider."
  (auth-source-pick-first-password :host (copilot--provider-host)))

(defun copilot-login ()
  "Deprecated login command retained for compatibility."
  (interactive)
  (user-error "GitHub device login is removed; configure API credentials via auth-source"))

(defun copilot-logout ()
  "Deprecated logout command retained for compatibility."
  (interactive)
  (user-error "GitHub device logout is removed; manage credentials via auth-source"))

;;
;; diagnose
;;

(defun copilot-diagnose ()
  "Restart the Copilot server and send a test completion request.
Shuts down any running server, starts a fresh one, and fires a
`llm-ls/getCompletions' request for the current buffer.
The result is logged to *Messages*: look for \"Copilot: Copilot OK.\"
on success, or an error/timeout message on failure."
  (interactive)
  (copilot--shutdown-server)
  ;; We are going to send a test request for the current buffer so we have to activate the mode
  ;; if it is not already activated.
  ;; If it the mode is already active, we have to make sure the current buffer is loaded in the
  ;; server.
  (if copilot-mode
      (copilot--on-doc-focus (selected-window))
    (copilot-mode))
  (copilot--async-request 'llm-ls/getCompletions
                          (copilot--inline-completion-params 1)
                          :success-fn (lambda (_)
                                        (copilot--log 'info "Copilot OK."))
                          :timeout-fn (lambda ()
                                        (copilot--log 'warning "Copilot server timeout."))))

;;
;; completion model selection
;;

(defun copilot-select-completion-model ()
  "Deprecated model selector — use `copilot-select-preset' instead."
  (interactive)
  (call-interactively #'copilot-select-preset))

;;
;; Auto completion
;;

;; based on https://code.visualstudio.com/docs/languages/identifiers
;; (more here https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
(defvar copilot-major-mode-alist '(("rustic" . "rust")
                                   ("cperl" . "perl")
                                   ("c++" . "cpp")
                                   ("clojure" . "clojure")
                                   ("clojurescript" . "clojure")
                                   ("objc" . "objective-c")
                                   ("cuda" . "cuda-cpp")
                                   ("docker-compose" . "dockercompose")
                                   ("coffee" . "coffeescript")
                                   ("js" . "javascript")
                                   ("js2" . "javascript")
                                   ("js2-jsx" . "javascriptreact")
                                   ("typescript-tsx" . "typescriptreact")
                                   ("rjsx" . "typescriptreact")
                                   ("less-css" . "less")
                                   ("caml" . "ocaml")
                                   ("tuareg" . "ocaml")
                                   ("text" . "plaintext")
                                   ("ess-r" . "r")
                                   ("enh-ruby" . "ruby")
                                   ("shell-script" . "shellscript")
                                   ("sh" . "shellscript")
                                   ("visual-basic" . "vb")
                                   ("nxml" . "xml"))
  "Alist mapping major mode names (with -mode removed) to copilot language ID's.")

(defvar copilot-minor-mode-alist '(("git-commit" . "git-commit"))
  "Alist mapping minor mode names (with -mode removed) to copilot language ID's.")

(defvar-local copilot--completion-cache nil)
(defvar-local copilot--completion-idx 0)

(defvar-local copilot--completion-request-id nil
  "Request ID of the in-flight completion request, or nil.")

(defvar-local copilot--completion-initiated-p nil
  "Non-nil when `copilot-complete' was called during the current command.
Used to prevent `copilot--post-command' from immediately cancelling
a request that was just initiated by a wrapper command.")

(defun copilot--cancel-completion ()
  "Cancel the in-flight completion request, if any.
Sends `$/cancelRequest' to the server and resets the stored request ID."
  (when copilot--completion-request-id
    (when (copilot--connection-alivep)
      (jsonrpc-notify copilot--connection
                      '$/cancelRequest
                      (list :id copilot--completion-request-id)))
    (setq copilot--completion-request-id nil)))

(defvar-local copilot--indent-warning-printed-p nil
  "Flag indicating whether indent warning was already printed.")

(defun copilot--infer-indentation-offset ()
  "Infer indentation offset."
  (or (let ((mode major-mode))
        (while (and (not (assq mode copilot-indentation-alist))
                    (setq mode (get mode 'derived-mode-parent))))
        (when mode
          (let ((indent-spec (alist-get mode copilot-indentation-alist)))
            (cond
             ((listp indent-spec)
              (cl-some (lambda (s)
                         (cond ((numberp s) s)
                               ((and (boundp s) (numberp (symbol-value s)))
                                (symbol-value s))))
                       indent-spec))
             ((functionp indent-spec) ; editorconfig 0.11.0+
              ;; This points to a setter, which do not call
              nil)))))
      (progn
        (when (and
               (not copilot-indent-offset-warning-disable)
               (not copilot--indent-warning-printed-p))
          (display-warning '(copilot copilot-no-mode-indent)
                           "copilot--infer-indentation-offset found no mode-specific indentation offset.")
          (setq-local copilot--indent-warning-printed-p t))
        tab-width)))

(defun copilot--workspace-root ()
  "Return the root directory of the current workspace, or nil."
  (when buffer-file-name
    (let ((root (or (and (fboundp 'project-current)
                         (when-let* ((proj (project-current)))
                           (project-root proj)))
                    (and (fboundp 'projectile-project-root)
                         (projectile-project-root))
                    (and (fboundp 'vc-root-dir)
                         (vc-root-dir)))))
      (when root
        (file-truename root)))))

(defun copilot--get-relative-path ()
  "Get relative path to current buffer."
  (cond
   ((not buffer-file-name)
    "")
   (t
    (if-let* ((root (copilot--workspace-root)))
        (file-relative-name buffer-file-name root)
      (file-name-nondirectory buffer-file-name)))))

(defun copilot--path-to-uri (path)
  "Convert file PATH to a URI string."
  (cond
   ((and (eq system-type 'windows-nt)
         (not (string-prefix-p "/" path)))
    (concat "file:///" (url-encode-url path)))
   (t
    (concat "file://" (url-encode-url path)))))

(defun copilot--get-uri ()
  "Get URI of current buffer."
  (if buffer-file-name
      (copilot--path-to-uri buffer-file-name)
    (concat "file:///buffer/" (url-encode-url (buffer-name (current-buffer))))))

(defun copilot--get-source ()
  "Get source code from current buffer."
  (save-restriction
    (widen)
    (let* ((p (point))
           (pmax (point-max))
           (pmin (point-min))
           (half-window (/ copilot-max-char 2)))
      (when (and buffer-file-name
                 (>= copilot-max-char 0)
                 (> pmax copilot-max-char))
        (unless copilot-max-char-warning-disable
          (display-warning '(copilot copilot-exceeds-max-char)
                           (format "%s size exceeds 'copilot-max-char' (%s), copilot completions may not work"
                                   (current-buffer) copilot-max-char))))
      (cond
       ;; using whole buffer
       ((or (< copilot-max-char 0) (< pmax copilot-max-char))
        (setq-local copilot--line-bias 1)
        (buffer-substring-no-properties pmin pmax))
       ;; truncate buffer head
       ((< (- pmax p) half-window)
        (let ((start (max pmin (- pmax copilot-max-char))))
          (setq-local copilot--line-bias (line-number-at-pos start))
          (buffer-substring-no-properties start pmax)))
       ;; truncate buffer tail
       ((< (- p pmin) half-window)
        (setq-local copilot--line-bias 1)
        (buffer-substring-no-properties pmin (min pmax (+ pmin copilot-max-char))))
       ;; truncate head and tail
       (t
        (let ((start (max pmin (- p half-window)))
              (end (min pmax (+ p half-window))))
          (setq-local copilot--line-bias (line-number-at-pos start))
          (buffer-substring-no-properties start end)))))))

(defun copilot--get-minor-mode-language-id ()
  "Get language ID from minor mode if available."
  (let ((pair
         (seq-find
          (lambda (pair)
            (let ((minor-mode-symbol (intern (concat (car pair) "-mode"))))
              (and (boundp minor-mode-symbol) (symbol-value minor-mode-symbol))))
          copilot-minor-mode-alist)))
    (cdr pair)))

(defun copilot--get-major-mode-language-id ()
  "Get language ID from major mode."
  (let ((major-mode-symbol (copilot--mode-symbol (symbol-name major-mode))))
    (alist-get major-mode copilot-major-mode-alist major-mode-symbol nil 'equal)))

(defun copilot--get-language-id ()
  "Get language ID of current buffer."
  (or (copilot--get-minor-mode-language-id)
      (copilot--get-major-mode-language-id)))

(defun copilot--utf16-offset ()
  "Return the number of UTF-16 code units from line start to point.
Characters above U+FFFF (e.g. emoji) count as 2 UTF-16 code units."
  (let ((offset 0)
        (p (line-beginning-position)))
    (while (< p (point))
      (let ((ch (char-after p)))
        (setq offset (+ offset (if (>= ch #x10000) 2 1)))
        (setq p (1+ p))))
    offset))

(defun copilot--utf16-strlen (str)
  "Return the UTF-16 code-unit length of STR."
  (let ((offset 0)
        (i 0)
        (len (length str)))
    (while (< i len)
      (let ((ch (aref str i)))
        (setq offset (+ offset (if (>= ch #x10000) 2 1)))
        (setq i (1+ i))))
    offset))

(defun copilot--goto-utf16-offset (utf16-offset)
  "Move point forward by UTF16-OFFSET UTF-16 code units from line start.
Point must be at line beginning before calling this."
  (let ((remaining utf16-offset))
    (while (and (> remaining 0) (not (eolp)))
      (let ((ch (char-after)))
        (setq remaining (- remaining (if (>= ch #x10000) 2 1))))
      (forward-char 1))))

(defun copilot--lsp-pos (&optional pos)
  "Return an LSP position plist for buffer POS.
POS defaults to point.  Character offset is in UTF-16 code units."
  (save-excursion
    (when pos (goto-char pos))
    (list :line (- (line-number-at-pos) copilot--line-bias)
          :character (copilot--utf16-offset))))

(defun copilot--generate-doc ()
  "Generate doc parameters for completion request."
  (save-restriction
    (widen)
    (let ((indent (copilot--infer-indentation-offset)))
      (list :version copilot--doc-version
            :tabSize indent
            ;; indentSize doesn't not appear to be used, but has been in this code
            ;; base from the start. For now leave it as is.
            :indentSize indent
            :insertSpaces (if indent-tabs-mode :json-false t)
            :path (buffer-file-name)
            :uri (copilot--get-uri)
            :relativePath (copilot--get-relative-path)
            :languageId (copilot--get-language-id)
            :position (copilot--lsp-pos)))))

(defun copilot--inline-completion-params (trigger-kind)
  "Build parameters for llm-ls/getCompletions.
TRIGGER-KIND is 1 for manual invocation, 2 for automatic."
  (save-restriction
    (widen)
    (let ((position (copilot--lsp-pos))
          (api-token (copilot--get-api-key)))
      (append
       (list :textDocument (list :uri (copilot--get-uri))
             :position position
             :model copilot-model
             :backend copilot-backend
             :url copilot-backend-url
             :contextWindow copilot-context-window
             :fim (list :enabled (if copilot-fim-enabled t :json-false)
                        :prefix copilot-fim-prefix
                        :middle copilot-fim-middle
                        :suffix copilot-fim-suffix)
             :requestBody copilot-request-body
             :tokensToClear (vconcat copilot-tokens-to-clear)
             :ide "emacs"
             :triggerKind trigger-kind
             :tlsSkipVerifyInsecure :json-false
             :disableUrlPathCompletion :json-false)
       (when copilot-provider (list :provider copilot-provider))
       (when api-token (list :apiToken api-token))
       (when copilot-tokenizer-config (list :tokenizerConfig copilot-tokenizer-config))))))

(defun copilot--normalize-llm-ls-response (response)
  "Normalize RESPONSE from llm-ls/getCompletions to internal completion items."
  (let* ((request-id (or (plist-get response :request_id)
                         (plist-get response :requestId)))
         (position (copilot--lsp-pos))
         (line (plist-get position :line))
         (character (plist-get position :character)))
    (mapcar
     (lambda (completion)
       (let* ((generated-text (or (plist-get completion :generated_text)
                                  (plist-get completion :generatedText) ""))
              (end-character (+ character (copilot--utf16-strlen generated-text))))
         (list :uuid request-id
               :text generated-text
               :range (list :start (list :line line :character character)
                            :end (list :line line :character end-character))
               :insertText generated-text)))
     (append (plist-get response :completions) nil))))

(defun copilot--normalize-completion-response (response)
  "Normalize completion RESPONSE to a list of items."
  (cond
   ((null response) nil)
   ((plist-get response :completions)
    (copilot--normalize-llm-ls-response response))
   ((vectorp response) (append response nil))
   ((plist-get response :items)
    (append (plist-get response :items) nil))
   (t nil)))

(defun copilot--get-completion (callback &optional trigger-kind)
  "Get completion with CALLBACK.
TRIGGER-KIND is 1 for invoked, 2 for automatic (default)."
  (copilot--cancel-completion)
  (setq copilot--completion-request-id
        (copilot--async-request 'llm-ls/getCompletions
                                (copilot--inline-completion-params (or trigger-kind 2))
                                :success-fn callback
                                :timeout copilot-completion-timeout
                                :error-fn (lambda (err)
                                            (unless (= (plist-get err :code) -32800) ; Request canceled
                                              (copilot--log 'error "llm-ls/getCompletions failed: %S"
                                                            err))))))

(defun copilot--cycle-completion (direction)
  "Cycle completion with DIRECTION."
  (let* ((items copilot--completion-cache)
         (len (length items)))
    (cond ((or (null items) (zerop len))
           (copilot--log 'warning "No completion is available."))
          ((= len 1)
           (copilot--log 'warning "Only one completion is available."))
          (t
           (setq copilot--completion-idx (mod (+ copilot--completion-idx direction) len))
           (copilot--show-completion (nth copilot--completion-idx items))))))

(defun copilot--overlay-visible ()
  "Return whether the `copilot--overlay' is available."
  (and (overlayp copilot--overlay)
       (overlay-buffer copilot--overlay)))

(defun copilot-next-completion ()
  "Cycle to next completion."
  (interactive)
  (when (copilot--overlay-visible)
    (copilot--cycle-completion 1)))

(defun copilot-previous-completion ()
  "Cycle to previous completion."
  (interactive)
  (when (copilot--overlay-visible)
    (copilot--cycle-completion -1)))

(defvar copilot--panel-lang nil
  "Language of current panel solutions.")

(defvar copilot--request-handlers (make-hash-table :test 'equal)
  "Hash table storing request handlers.")

(defun copilot-on-request (method handler)
  "Register a request HANDLER for the given METHOD.
Each request METHOD can have only one HANDLER."
  (puthash method handler copilot--request-handlers))

(defun copilot--handle-request (_ method msg)
  "Handle MSG of type METHOD by calling the appropriate registered handler."
  (let ((handler (gethash method copilot--request-handlers)))
    (when handler
      (funcall handler msg))))

(defvar copilot--notification-handlers (make-hash-table :test 'equal)
  "Hash table storing lists of notification handlers.")

(defun copilot-on-notification (method handler)
  "Register a notification HANDLER for the given METHOD."
  (let ((handlers (gethash method copilot--notification-handlers '())))
    (puthash method (cons handler handlers) copilot--notification-handlers)))

(defun copilot--handle-notification (_ method msg)
  "Handle MSG of type METHOD by calling all appropriate registered handlers."
  (let ((handlers (gethash method copilot--notification-handlers '())))
    (dolist (handler handlers)
      (funcall handler msg))))

(copilot-on-notification
 'window/logMessage
 (lambda (msg)
   (copilot--dbind (((:type log-level)) ((:message log-msg))) msg
                   (with-current-buffer (get-buffer-create "*copilot-language-server-log*")
                     (save-excursion
                       (goto-char (point-max))
                       (insert (propertize (concat log-msg "\n")
                                           'face (pcase log-level
                                                   (4 'shadow)
                                                   (3 'success)
                                                   (2 'warning)
                                                   (1 'error)))))))))

;; PanelSolution/PanelSolutionsDone notifications removed — panel now uses
;; llm-ls/getCompletions response directly in copilot-panel-complete.

(copilot-on-notification
 'didChangeStatus
 (lambda (msg)
   (copilot--dbind (kind busy message) msg
                   (setq copilot--status (list :kind kind :busy (eq busy t) :message message))
                   (force-mode-line-update t))))

(copilot-on-request
 'window/showMessageRequest
 (lambda (msg)
   (copilot--dbind (type message actions) msg
                   (if (and actions (vectorp actions) (> (length actions) 0))
                       (let* ((titles (mapcar (lambda (a) (plist-get a :title))
                                              (append actions nil)))
                              (chosen (completing-read
                                       (format "Copilot (%s): "
                                               (pcase type (1 "Error") (2 "Warning")
                                                      (3 "Info") (_ "Log")))
                                       titles nil t)))
                         (list :title chosen))
                     (copilot--log (pcase type (1 'error) (2 'warning) (_ 'info))
                                   "%s" message)
                     :json-null))))

(copilot-on-request
 'window/showDocument
 (lambda (msg)
   (condition-case _err
       (copilot--dbind (uri external takeFocus) msg
                       (let ((focus (not (eq takeFocus :json-false))))
                         (cond
                          ((or (eq external t) (string-match-p "\\`https?://" uri))
                           (browse-url uri))
                          ((string-prefix-p "file://" uri)
                           (let* ((path (url-unhex-string
                                         (string-remove-prefix "file://" uri)))
                                  (buf (find-file-noselect path)))
                             (if focus
                                 (find-file path)
                               (display-buffer buf)))))
                         (list :success t)))
     (error (list :success :json-false)))))

(copilot-on-notification
 '$/progress
 (lambda (msg)
   (copilot--dbind (token value) msg
                   (let ((kind (plist-get value :kind)))
                     (cond
                      ((equal kind "begin")
                       (puthash token
                                (list :title (plist-get value :title)
                                      :message (plist-get value :message)
                                      :percentage (plist-get value :percentage))
                                copilot--progress-sessions))
                      ((equal kind "report")
                       (let ((session (gethash token copilot--progress-sessions)))
                         (when session
                           (when (plist-member value :message)
                             (plist-put session :message (plist-get value :message)))
                           (when (plist-member value :percentage)
                             (plist-put session :percentage (plist-get value :percentage))))))
                      ((equal kind "end")
                       (remhash token copilot--progress-sessions)))
                     (force-mode-line-update t)))))

(defun copilot--get-panel-completions (callback)
  "Get panel completions with CALLBACK via llm-ls/getCompletions."
  (copilot--async-request 'llm-ls/getCompletions
                          (copilot--inline-completion-params 1)
                          :success-fn callback
                          :timeout copilot-completion-timeout
                          :timeout-fn (lambda ()
                                        (copilot--log 'warning "Copilot server timeout."))))


(defun copilot-panel-complete ()
  "Pop a buffer with a list of suggested completions based on the current file."
  (interactive)
  (require 'org)
  (setq copilot--last-doc-version copilot--doc-version)
  (setq copilot--panel-lang (copilot--get-language-id))

  (copilot--get-panel-completions
   (lambda (response)
     (let ((completions (copilot--normalize-completion-response response)))
       (with-current-buffer (get-buffer-create "*copilot-panel*")
         (erase-buffer)
         (org-mode)
         (dolist (item completions)
           (let ((text (or (plist-get item :text)
                           (plist-get item :insertText) "")))
             (unless (string-blank-p text)
               (insert "* Solution\n"
                       "#+BEGIN_SRC " copilot--panel-lang "\n"
                       text "\n#+END_SRC\n\n"))))
         (goto-char (point-min))
         (copilot--log 'info "Panel: %d completions." (length completions))
         (display-buffer (current-buffer)))))))

;;
;; UI
;;

(defun copilot-current-completion ()
  "Get current completion."
  (and (copilot--overlay-visible)
       (overlay-get copilot--overlay 'completion)))

(defface copilot-overlay-face
  '((t :inherit shadow))
  "Face for Copilot overlay.")

(defvar-local copilot--real-posn nil
  "Posn information without overlay.
To work around posn problems with after-string property.")

(defconst copilot-completion-map (make-sparse-keymap)
  "Keymap for Copilot completion overlay.")

(defun copilot--posn-advice (&rest args)
  "Remap posn if in `copilot-mode' with ARGS."
  (when copilot-mode
    (let ((pos (or (car-safe args) (point))))
      (when (and copilot--real-posn
                 (eq pos (car copilot--real-posn)))
        (cdr copilot--real-posn)))))

(defun copilot--get-or-create-keymap-overlay ()
  "Make or return the local copilot--keymap-overlay."
  (unless (overlayp copilot--keymap-overlay)
    (setq copilot--keymap-overlay (make-overlay 1 1 nil nil t))
    (overlay-put copilot--keymap-overlay 'keymap copilot-completion-map)
    (overlay-put copilot--keymap-overlay 'priority 101))
  copilot--keymap-overlay)

(defun copilot--get-overlay ()
  "Create or get overlay for Copilot."
  (unless (overlayp copilot--overlay)
    (setq copilot--overlay (make-overlay 1 1 nil nil t))
    (overlay-put copilot--overlay 'priority 100)
    (overlay-put
     copilot--overlay 'keymap-overlay (copilot--get-or-create-keymap-overlay)))
  copilot--overlay)

(defun copilot--overlay-end (ov)
  "Return the end position of overlay OV."
  (- (line-end-position) (overlay-get ov 'tail-length)))

(defun copilot--set-overlay-text (ov completion)
  "Set overlay OV with COMPLETION."
  (move-overlay ov (point) (line-end-position))

  ;; set overlay position for the keymap, to activate copilot-completion-map
  ;;
  ;; if the point is at the end of the buffer, we will create a
  ;; 0-length buffer. But this is ok, since the keymap will still
  ;; activate _so long_ as no other overlay contains the point.
  ;;
  ;; see https://github.com/copilot-emacs/copilot.el/issues/251 for details.
  (move-overlay (overlay-get ov 'keymap-overlay) (point) (min (point-max) (+ 1 (point))))

  (let* ((tail (buffer-substring (copilot--overlay-end ov) (line-end-position)))
         (p-completion (concat (propertize completion 'face 'copilot-overlay-face)
                               tail)))
    (if (eolp)
        (progn
          (overlay-put ov 'after-string "") ; make sure posn is correct
          (setq copilot--real-posn (cons (point) (posn-at-point)))
          (put-text-property 0 1 'cursor t p-completion)
          (overlay-put ov 'display "")
          (overlay-put ov 'after-string p-completion))
      (overlay-put ov 'display (substring p-completion 0 1))
      (overlay-put ov 'after-string (substring p-completion 1)))
    (overlay-put ov 'completion completion)
    (overlay-put ov 'start (point))))

(defun copilot--display-overlay-completion (completion command full-insert-text start end)
  "Show COMPLETION with COMMAND and FULL-INSERT-TEXT between START and END.

`save-excursion' is not necessary since there is only one caller, and they are
already saving an excursion.  This is also a private function."
  (copilot-clear-overlay)
  (when (and (not (string-blank-p completion))
             (or (<= start (point))))
    (let* ((ov (copilot--get-overlay)))
      (overlay-put ov 'tail-length (- (line-end-position) end))
      (copilot--set-overlay-text ov completion)
      (overlay-put ov 'command command)
      (overlay-put ov 'full-insert-text full-insert-text)
      (overlay-put ov 'completion-start start))))

(defun copilot-clear-overlay (&optional _is-accepted)
  "Clear Copilot overlay."
  (interactive)
  (copilot--cancel-completion)
  (when (copilot--overlay-visible)
    (delete-overlay copilot--overlay)
    (delete-overlay copilot--keymap-overlay)
    (setq copilot--real-posn nil)))

(defun copilot-accept-completion (&optional transform-fn)
  "Accept completion.
Return t if there is a completion.  Use TRANSFORM-FN to transform completion if
provided."
  (interactive)
  (when (copilot--overlay-visible)
    (let* ((completion (overlay-get copilot--overlay 'completion))
           (start (overlay-get copilot--overlay 'start))
           (end (copilot--overlay-end copilot--overlay))
           (command (overlay-get copilot--overlay 'command))
           (full-insert-text (overlay-get copilot--overlay 'full-insert-text))
           (t-completion (funcall (or transform-fn #'identity) completion))
           (completion-start (overlay-get copilot--overlay 'completion-start)))
      ;; If there is extra indentation before the point, delete it and shift the completion
      (when (and (< completion-start (point))
                 ;; Region we are about to delete contains only blanks …
                 (string-blank-p (buffer-substring-no-properties completion-start (point)))
                 ;; … *and* everything from BOL to completion-start is blank
                 ;; as well — i.e. we are really inside the leading indentation.
                 (string-blank-p (buffer-substring-no-properties (line-beginning-position) completion-start)))
        (setq start completion-start)
        (setq end (- end (- (point) completion-start)))
        (delete-region completion-start (point)))
      (let ((is-partial (and (string-prefix-p t-completion completion)
                             (not (string-equal t-completion completion)))))
        (copilot-clear-overlay t)
        (if (derived-mode-p 'vterm-mode)
            (progn
              (unless is-partial (vterm-delete-region start end))
              (vterm-insert t-completion))
          (unless is-partial (delete-region start end))
          (insert t-completion))
        ;; if it is a partial completion, show remaining text
        (when is-partial
          (copilot--set-overlay-text (copilot--get-overlay) (string-remove-prefix t-completion completion))))
      t)))

(defmacro copilot--define-accept-completion-by-action (func-name action)
  "Define function FUNC-NAME to accept completion by ACTION."
  `(defun ,func-name (&optional n)
     (interactive "p")
     (setq n (or n 1))
     (copilot-accept-completion (lambda (completion)
                                  (with-temp-buffer
                                    (insert completion)
                                    (goto-char (point-min))
                                    (funcall ,action n)
                                    (buffer-substring-no-properties (point-min) (point)))))))

(copilot--define-accept-completion-by-action copilot-accept-completion-by-word #'forward-word)
(copilot--define-accept-completion-by-action copilot-accept-completion-by-line #'forward-line)
(copilot--define-accept-completion-by-action copilot-accept-completion-by-sentence #'forward-sentence)
(copilot--define-accept-completion-by-action copilot-accept-completion-by-paragraph #'forward-paragraph)

(defun copilot--uppercase-char-p (char)
  "Return non-nil when CHAR is uppercase in the current locale."
  (and (characterp char)
       (let ((up (upcase char))
             (down (downcase char)))
         (and (not (eq up down)) (eq char up)))))

(defun copilot--completion-chunk-to-char (completion char count include-char)
  "Return COMPLETION substring up to CHAR.
COUNT specifies the occurrence.  INCLUDE-CHAR toggles whether CHAR stays
in.  Uppercase CHAR disables `case-fold-search'."
  (let ((count (or count 1)))
    (when (<= count 0)
      (user-error "COUNT must be positive"))
    (with-temp-buffer
      (insert completion)
      (goto-char (point-min))
      (let ((case-fold-search (if (copilot--uppercase-char-p char)
                                  nil case-fold-search)))
        (search-forward (char-to-string char) nil nil count)
        (unless include-char
          (backward-char))
        (buffer-substring-no-properties (point-min) (point))))))

(defun copilot-accept-completion-up-to-char (char &optional count)
  "Accept completion up to but excluding CHAR.
COUNT must be positive; signal an error if CHAR does not occur COUNT times.
Uppercase CHAR disables `case-fold-search', mirroring `zap-up-to-char'."
  (interactive (list (read-char "Accept completion up to char: ")
                     (prefix-numeric-value current-prefix-arg)))
  (copilot-accept-completion
   (lambda (completion)
     (copilot--completion-chunk-to-char completion char count nil))))

(defun copilot-accept-completion-to-char (char &optional count)
  "Accept completion up to and including CHAR.
COUNT must be positive; signal an error if CHAR does not occur COUNT times.
Uppercase CHAR disables `case-fold-search', mirroring `zap-to-char'."
  (interactive (list (read-char "Accept completion through char: ")
                     (prefix-numeric-value current-prefix-arg)))
  (copilot-accept-completion
   (lambda (completion)
     (copilot--completion-chunk-to-char completion char count t))))

(defun copilot--show-completion (completion-data)
  "Show COMPLETION-DATA."
  (when (copilot--satisfy-display-predicates)
    (copilot--dbind
     (((:insertText insert-text)) command range)
     completion-data
     (save-excursion
       (save-restriction
         (widen)
         (let* ((p (point))
                (full-insert-text insert-text)
                (line (map-nested-elt range '(:start :line)))
                (start-char (map-nested-elt range '(:start :character)))
                (end-char (map-nested-elt range '(:end :character)))
                (goto-line! (lambda ()
                              (goto-char (point-min))
                              (forward-line (1- (+ line copilot--line-bias)))))
                (start (progn
                         (funcall goto-line!)
                         (copilot--goto-utf16-offset start-char)
                         (let* ((cur-line (buffer-substring-no-properties (point) (line-end-position)))
                                (common-prefix-len (length (copilot--string-common-prefix insert-text cur-line))))
                           (setq insert-text (substring insert-text common-prefix-len))
                           (forward-char common-prefix-len)
                           (point))))
                (end (progn
                       (funcall goto-line!)
                       (copilot--goto-utf16-offset end-char)
                       (point)))
                (fixed-completion (copilot-balancer-fix-completion start end insert-text)))
           (goto-char p)
           (pcase-let ((`(,start ,end ,balanced-text) fixed-completion))
             (copilot--display-overlay-completion balanced-text command full-insert-text start end))))))))

(defun copilot--ensure-doc-open ()
  "Ensure the current buffer has been opened with the Copilot server.
Sends workspace folder and `textDocument/didOpen' notifications if
the buffer has not been registered yet.  Safe to call multiple times."
  (when-let* ((root (copilot--workspace-root))
              (root-uri (copilot--path-to-uri root)))
    (unless (member root-uri copilot--workspace-folders)
      (push root-uri copilot--workspace-folders)
      (copilot--notify 'workspace/didChangeWorkspaceFolders
                       (list :event
                             (list :added (vector (list :uri root-uri
                                                        :name (file-name-nondirectory
                                                               (directory-file-name root))))
                                   :removed [])))))
  (unless (seq-contains-p copilot--opened-buffers (current-buffer))
    (add-to-list 'copilot--opened-buffers (current-buffer))
    (copilot--notify 'textDocument/didOpen
                     (list :textDocument (list :uri (copilot--get-uri)
                                               :languageId (copilot--get-language-id)
                                               :version copilot--doc-version
                                               :text (copilot--get-source))))))

(defun copilot--on-doc-focus (window)
  "Notify that the document WINDOW has been focussed or opened."
  ;; When switching windows, this function is called twice, once for the
  ;; window losing focus and once for the window gaining focus. We only want to
  ;; send a notification for the window gaining focus and only if the buffer has
  ;; copilot-mode enabled.
  (when (and copilot-mode (eq window (selected-window)))
    (if (seq-contains-p copilot--opened-buffers (current-buffer))
        (copilot--notify 'textDocument/didFocus
                         (list :textDocument (list :uri (copilot--get-uri))))
      (copilot--ensure-doc-open))))

(defun copilot--on-doc-close (&rest _args)
  "Notify that the document has been closed."
  (when (seq-contains-p copilot--opened-buffers (current-buffer))
    (when (copilot--connection-alivep)
      (jsonrpc-notify copilot--connection 'textDocument/didClose
                      (list :textDocument (list :uri (copilot--get-uri)))))
    (setq copilot--opened-buffers (delete (current-buffer) copilot--opened-buffers))))

;;;###autoload
(defun copilot-complete ()
  "Complete at the current point."
  (interactive)
  (copilot--ensure-doc-open)
  (setq copilot--last-doc-version copilot--doc-version)
  (setq copilot--completion-initiated-p t)

  (setq copilot--completion-cache nil)
  (setq copilot--completion-idx 0)

  (let ((called-interactively (called-interactively-p 'interactive))
        (request-doc-version copilot--doc-version))
    (copilot--get-completion
     (lambda (response)
       (when (= request-doc-version copilot--doc-version)
         (let ((items (copilot--normalize-completion-response response)))
           (setq copilot--completion-cache items)
           (if items
               (copilot--show-completion (car items))
             (when called-interactively
               (copilot--log 'warning "No completion is available."))))))
     (if called-interactively 1 2))))

;;
;; integration with track-changes
;;

(defvar-local copilot--track-changes-id nil
  "Tracker id from `track-changes-register' for this buffer.")

(defun copilot--lsp-range-end-from-oldtext (beg oldtext)
  "Compute old end position plist for change at BEG replacing OLDTEXT."
  (if (string-empty-p oldtext)
      ;; Optimization for pure insertions
      (copilot--lsp-pos beg)
    (let* ((start (copilot--lsp-pos beg))
           (start-line (plist-get start :line))
           (start-char (plist-get start :character))
           (end-info (with-temp-buffer
                       (insert oldtext)
                       (goto-char (point-max))
                       (cons (1- (line-number-at-pos))
                             (copilot--utf16-offset))))
           (num-newlines (car end-info))
           (end-char (cdr end-info)))
      (list :line (+ start-line num-newlines)
            :character (if (= num-newlines 0)
                           (+ start-char (copilot--utf16-strlen oldtext))
                         end-char)))))

(defun copilot--track-changes-signal (id &optional _distance)
  "Handle `track-changes' signal for given tracker ID.
Fetch the changes and notify the language server."
  (condition-case err
      (save-restriction
        (widen)
        (track-changes-fetch
         id
         (lambda (beg end before)
           (unless (eq before 'error)
             (save-restriction
               (widen)
               (let* ((new-text (buffer-substring-no-properties beg end))
                      (start-pos (copilot--lsp-pos beg))
                      (end-pos (copilot--lsp-range-end-from-oldtext beg (or before ""))))
                 (cl-incf copilot--doc-version)
                 (copilot--notify
                  'textDocument/didChange
                  (list :textDocument (list :uri (copilot--get-uri)
                                            :version copilot--doc-version)
                        :contentChanges
                        (vector
                         (list :range (list :start start-pos :end end-pos)
                               :text new-text))))))))))
    (error
     (copilot--log 'error "Change fetch failed: %s" (error-message-string err)))))

;;
;; minor mode
;;

(defcustom copilot-disable-predicates nil
  "A list of predicate functions with no argument to disable Copilot.
Copilot will not be triggered if any predicate returns t."
  :type '(repeat function)
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defcustom copilot-enable-predicates '(evil-insert-state-p copilot--buffer-changed)
  "A list of predicate functions with no argument to enable Copilot.
Copilot will be triggered only if all predicates return t."
  :type '(repeat function)
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defcustom copilot-disable-display-predicates nil
  "A list of predicate functions with no argument to disable Copilot.
Copilot will not show completions if any predicate returns t."
  :type '(repeat function)
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defcustom copilot-enable-display-predicates nil
  "A list of predicate functions with no argument to enable Copilot.
Copilot will show completions only if all predicates return t."
  :type '(repeat function)
  :group 'copilot
  :package-version '(copilot . "0.1"))

(defun copilot--satisfy-predicates (enable disable)
  "Return t if all predicates in ENABLE return t and none in DISABLE do."
  (and (cl-every (lambda (pred)
                   (if (functionp pred) (funcall pred) t))
                 enable)
       (cl-notany (lambda (pred)
                    (if (functionp pred) (funcall pred) nil))
                  disable)))

(defun copilot--pre-command ()
  "Handle `pre-command-hook' for Copilot.
Clear the overlay for commands in `copilot-clear-overlay-on-commands' so
that display-based motions (such as `beginning-of-visual-line') work
consistently even when the overlay is visible."
  (when (and this-command
             (copilot--overlay-visible)
             (memq this-command copilot-clear-overlay-on-commands))
    (copilot-clear-overlay)))

(defun copilot--satisfy-trigger-predicates ()
  "Return t if all trigger predicates are satisfied."
  (copilot--satisfy-predicates copilot-enable-predicates copilot-disable-predicates))

(defun copilot--satisfy-display-predicates ()
  "Return t if all display predicates are satisfied."
  (copilot--satisfy-predicates copilot-enable-display-predicates copilot-disable-display-predicates))

(defun copilot--post-command ()
  "Complete in `post-command-hook' hook."
  (let ((completion-initiated copilot--completion-initiated-p))
    (setq copilot--completion-initiated-p nil)
    (when (and this-command
               (not completion-initiated)
               (not (and (symbolp this-command)
                         (or
                          (string-prefix-p "copilot-" (symbol-name this-command))
                          (member this-command copilot-clear-overlay-ignore-commands)
                          ;; `this-original-command' captures remapped helpers like
                          ;; `universal-argument-more' and `digit-argument'.
                          (member this-original-command copilot-clear-overlay-ignore-commands)
                          (member this-original-command copilot--hardcoded-clear-overlay-ignore-commands)
                          (copilot--self-insert this-command)))))
      (copilot-clear-overlay)
      (when copilot--post-command-timer
        (cancel-timer copilot--post-command-timer))
      (when (numberp copilot-idle-delay)
        (setq copilot--post-command-timer
              (run-with-idle-timer copilot-idle-delay
                                   nil
                                   #'copilot--post-command-debounce
                                   (current-buffer)))))))

(defun copilot--self-insert (command)
  "Handle the case where the char just inserted is the start of the completion.
If so, update the overlays and continue.  COMMAND is the command that triggered
in `post-command-hook'."
  (when (and (eq command 'self-insert-command)
             (copilot--overlay-visible)
             (copilot--satisfy-display-predicates))
    (let* ((ov copilot--overlay)
           (completion (overlay-get ov 'completion)))
      ;; The char just inserted is the next char of completion
      (when (eq last-command-event (elt completion 0))
        (if (= (length completion) 1)
            ;; If there is only one char in the completion, accept it
            (copilot-accept-completion)
          (copilot--set-overlay-text ov (substring completion 1)))))))

(defun copilot--post-command-debounce (buffer)
  "Complete in BUFFER."
  (when (and (buffer-live-p buffer)
             (equal (current-buffer) buffer)
             copilot-mode
             (copilot--satisfy-trigger-predicates))
    (copilot-complete)
    ;; Clear the flag: idle timers don't trigger `post-command-hook', so the
    ;; flag would otherwise persist and cause the next real command to skip
    ;; overlay clearing.
    (setq copilot--completion-initiated-p nil)))

;;
;; Minor mode definition
;;

(defvar copilot-mode-map (make-sparse-keymap)
  "Keymap for Copilot minor mode.
Use this for custom bindings in `copilot-mode'.")

(easy-menu-define copilot-mode-menu copilot-mode-map "Copilot menu."
  '("Copilot"
    ["Complete" copilot-complete]
    ["Clear Overlay" copilot-clear-overlay]
    ["Accept Completion" copilot-accept-completion]
    ["Accept Completion by Word" copilot-accept-completion-by-word]
    ["Accept Completion by Line" copilot-accept-completion-by-line]
    ["Accept Completion by Paragraph" copilot-accept-completion-by-paragraph]
    ["Next Completion" copilot-next-completion]
    ["Previous Completion" copilot-previous-completion]
    ["Panel Complete" copilot-panel-complete]
    "--"
    ["Select Preset" copilot-select-preset]
    "--"
    ["Diagnose" copilot-diagnose]))

(defun copilot--mode-setup ()
  "Set up copilot mode."
  (add-hook 'pre-command-hook #'copilot--pre-command nil 'local)
  (add-hook 'post-command-hook #'copilot--post-command nil 'local)
  ;; Hook onto both window-selection-change-functions and window-buffer-change-functions
  ;; since both are separate ways of 'focussing' a buffer.
  (add-hook 'window-selection-change-functions #'copilot--on-doc-focus nil 'local)
  (add-hook 'window-buffer-change-functions #'copilot--on-doc-focus nil 'local)
  (add-hook 'kill-buffer-hook #'copilot--on-doc-close nil 'local)
  (unless copilot--track-changes-id
    (setq copilot--track-changes-id
          (track-changes-register #'copilot--track-changes-signal)))
  ;; The mode may be activated manually while focus remains on the current window/buffer.
  (copilot--on-doc-focus (selected-window)))

(defun copilot--mode-teardown ()
  "Tear down copilot mode."
  (remove-hook 'pre-command-hook #'copilot--pre-command 'local)
  (remove-hook 'post-command-hook #'copilot--post-command 'local)
  (remove-hook 'window-selection-change-functions #'copilot--on-doc-focus 'local)
  (remove-hook 'window-buffer-change-functions #'copilot--on-doc-focus 'local)
  (remove-hook 'kill-buffer-hook #'copilot--on-doc-close 'local)
  (when copilot--track-changes-id
    (track-changes-unregister copilot--track-changes-id)
    (setq copilot--track-changes-id nil))
  ;; Send the close event for the active buffer since activating the mode will open it again.
  (copilot--on-doc-close))

;;;###autoload
(define-minor-mode copilot-mode
  "Minor mode for Copilot."
  :init-value nil
  :lighter (:eval (copilot--status-lighter))
  (copilot-clear-overlay)
  (advice-add 'posn-at-point :before-until #'copilot--posn-advice)
  (if copilot-mode
      (copilot--mode-setup)
    (copilot--mode-teardown)))

(defun copilot-turn-on-unless-buffer-read-only ()
  "Turn on `copilot-mode' if the buffer is writable and not internal.
Skip read-only buffers, minibuffers, and hidden internal buffers
whose names start with a space."
  (unless (or buffer-read-only
              (minibufferp)
              (string-prefix-p " " (buffer-name)))
    (copilot-mode 1)))

;;;###autoload
(define-global-minor-mode global-copilot-mode
  copilot-mode copilot-turn-on-unless-buffer-read-only)

(provide 'copilot)
;;; copilot.el ends here
