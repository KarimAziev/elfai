;;; elfai.el --- An interface to OpenAI's GPT models -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Karim Aziiev <karim.aziiev@gmail.com>

;; Author: Karim Aziiev <karim.aziiev@gmail.com>
;; URL: https://github.com/KarimAziev/elfai
;; Version: 0.1.0
;; Keywords: tools
;; Package-Requires: ((emacs "29.1") (transient "0.6.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a set of tools to interact with OpenAI's GPT models
;; directly from Emacs. It allows users to send prompts to the model and
;; receive responses, which can be used for a variety of tasks such as
;; code completion, text generation, and more.

;; The package defines a number of custom variables and functions to handle
;; the communication with the OpenAI API, manage API keys, and process the
;; responses. It also includes a minor mode (`elfai-abort-mode') to monitor
;; and handle aborting GPT requests using `keyboard-quit' commands.

;; To use this package, you need to set your OpenAI API key using the
;; `elfai-api-key' custom variable. You can also customize the behavior of
;; the package by setting other provided custom variables.

;; The main entry points for interacting with the GPT models are the
;; `elfai-ask-and-insert', `elfai-complete-here', `elfai-create-image',
;; `elfai-create-image-variation', `elfai-recognize-image', and
;; `elfai-set-model' functions. These functions allow you to send prompts
;; to the model, generate images, create variations of images, recognize
;; content in images, and set the model for a given variable.

;; The package also provides utility functions for fetching and sorting
;; available GPT models, downloading images, and formatting time differences
;; in a human-readable way.

;; To get started, install the package, set your API key, and start using
;; the provided functions to interact with the GPT models.

;;; Code:

(declare-function text-property-search-backward "text-property-search")
(declare-function prop-match-value "text-property-search")

(defvar json-object-type)
(defvar json-array-type)
(defvar json-false)
(defvar json-null)
(defvar url-request-method)
(defvar url-request-data)
(defvar url-request-extra-headers)
(defvar url-http-end-of-headers)

(declare-function json-encode "json")
(declare-function json-read "json")
(declare-function json-read-from-string "json")
(declare-function url-host "url-parse")
(declare-function auth-source-search "auth-source")

(require 'transient)

(defcustom elfai-abort-on-keyboard-quit-count 3
  "Number of `keyboard-quit' presses before aborting GPT documentation requests.

Determines the number of consecutive `keyboard-quit' commands needed to abort an
active streaming request.

The default value is 3, meaning that pressing `keyboard-quit' three times in
quick succession will abort the request.

This variable is only effective when `elfai-use-stream' is non-nil, as
it applies to streaming requests.

If the number of `keyboard-quit' commands does not reach the set threshold, the
abort action will not be triggered."
  :group 'elfai
  :type 'integer)

(defcustom elfai-complete-prompt (cons "<<$0>>"
                                       "Directly below is a placeholder '<<$0>>' within a code or text snippet. You are tasked with replacing this placeholder. Only provide the precise code or text that should replace '<<$0>>'. Do not add any extra formatting, annotations, don't wrap it in ```.")
  "Placeholder and instructions for code/text snippet replacement.

Specifies the placeholder and instructions for completing prompts in code or
text snippets.

The value is a cons cell where the car is a string representing the placeholder
to be replaced, and the cdr is a string providing instructions for the
replacement.

The default placeholder is \"<<$0>>\". The instructions direct to replace the
placeholder with the exact code or text needed, without any extra formatting or
annotations."
  :group 'elfai
  :type '(cons string string))

(defcustom elfai-debug nil
  "Whether to enable debugging in the GPT documentation group."
  :group 'elfai
  :type 'boolean)

(defcustom elfai-api-key 'elfai-api-key-from-auth-source
  "An OpenAI API key (string).

Can also be a function of no arguments that returns an API
key (more secure)."
  :group 'elfai
  :type '(radio
          (string :tag "API key")
          (function-item elfai-api-key-from-auth-source)
          (function :tag "Function that returns the API key")))

(defcustom elfai-gpt-url "https://api.openai.com/v1/chat/completions"
  "The URL to the OpenAI GPT API endpoint for chat completions."
  :group 'elfai
  :type 'string)

(defcustom elfai-gpt-model "gpt-4-turbo-preview"
  "A string variable representing the API model for OpenAI."
  :group 'elfai
  :type 'string)

(defcustom elfai-gpt-temperature 0.1
  "The temperature for the OpenAI GPT model used.

This is a number between 0.0 and 2.0 that controls the randomness
of the response, with 2.0 being the most random.

The temperature controls the randomness of the output generated by the model. A
lower temperature results in more deterministic and less random completions,
while a higher temperature produces more diverse and random completions.

To adjust the temperature, set the value to the desired level. For example, to
make the model's output more deterministic, reduce the value closer to 0.1.
Conversely, to increase randomness, raise the value closer to 1.0."
  :group 'elfai
  :type 'number)

(defcustom elfai-images-dir "~/Pictures/gpt/"
  "Default directory for GPT template images.

Specifies the directory where images generated by the template should be saved.
The default location is \"~/Pictures/gpt/\".

This variable can be set to a string representing a directory path, a function
that returns a directory path when called, or the special value
`read-directory-name' which prompts the user to select a directory
interactively.

When a function is used, it should take no arguments and return a string that is
the path to the directory.

If the directory does not exist, it will be created automatically when saving
images."
  :group 'elfai
  :type '(radio
          (directory :tag "Directory")
          (function-item read-directory-name)
          (function :tag "Function that directory")))

(defcustom elfai-user-prompt-prefix "* "
  "Prefix for user prompts in elfai interactions.

A string used as a prefix for user prompts in the ElfaI interface.

The default value is a single character representing a user, but it can be
customized to any string that visually distinguishes user inputs from other
types of messages in the interface.

When parsing the buffer for user inputs, this prefix is used to identify and
trim user prompts, ensuring that only the actual input text is processed."
  :group 'elfai
  :type 'string)

(defcustom elfai-response-prefix "\n#+begin_src markdown\n"
  "Prefix for formatting responses in markdown.

Specifies the prefix to be inserted before responses in the assistant's output.
The default value is a newline followed by the Org mode source block declaration
for Markdown content.

This prefix is used to format the assistant's responses in a way that is
compatible with Org mode's syntax, allowing for seamless integration of the
responses into Org documents.

The value should be a string that represents the desired prefix. It can be
customized to fit different formatting needs or preferences for how the
assistant's responses are presented within Org mode documents."
  :group 'elfai
  :type 'string)

(defcustom elfai-response-suffix "\n#+end_src\n"
  "Suffix appended to responses.

A string appended to the end of responses generated by the assistant.

The default value is a newline followed by \"#+end_src\n\", commonly used to
denote the end of a source code block in Org mode documents.

Modifying this value allows customization of how responses are terminated, which
can be particularly useful when integrating the assistant's output into
documents or applications that use specific formatting conventions.

Ensure that the chosen suffix is compatible with the intended use case to avoid
formatting issues."
  :group 'elfai
  :type 'string)

(defcustom elfai-image-time-format "%Y_%m_%d_%H_%M_%S"
  "Format given to `format-time-string' which is appended to the image filename."
  :type 'directory
  :group 'elfai)

(defcustom elfai-image-auto-preview-enabled 0.2
  "Whether to auto preview image files in completing read."
  :type '(radio
          (boolean t)
          (number
           :tag "Enable after idle delay"
           :value 0.2))
  :group 'elfai)

(defcustom elfai-system-prompts '(""
                                  "Rewrite this function")
  "List of predefined system prompts.

A list of system prompts used to guide the generation of commit messages with
the help of a GPT model. Each prompt is a string that instructs the GPT model on
how to process the `git diff --cached` output and any partial commit message
provided by the user to create a complete and conventional commit message.

Each prompt should be crafted to provide clear and concise instructions to the
GPT model, ensuring that the generated commit message is relevant and adheres to
conventional commit standards. The prompts should not include any extraneous
information and should be formatted to fit within a 70-character width limit.

To use these prompts, select one from the list as the active prompt when
invoking the commit message generation function. The selected prompt will be
sent to the GPT model along with the `git diff --cached` output and any
user-provided commit message fragment to generate a complete commit message."
  :type '(repeat string)
  :group 'gpt-commit)

(defconst elfai-props-indicator '(elfai response rear-nonsticky t))

(defcustom elfai--stream-after-insert-hook nil
  "Hooks run after inserting stream response.

A hook that runs after inserting a response into the stream.

Hooks in this list are called with no arguments. They are intended to perform
post-insertion processing, such as updating display properties, refreshing
related UI elements, or triggering additional asynchronous operations based on
the newly inserted content.

Each function to be called by this hook should be added using `add-hook'. To
remove a function, use `remove-hook'. Functions can be any valid Lisp function
that requires no arguments.

This hook is particularly useful for extending or customizing the behavior of
the stream insertion process, allowing for a flexible response to dynamic
content updates."
  :group 'elfai
  :local t
  :type 'hook)


(defvar-local elfai-old-header-line nil)
(defvar-local elfai-curr-prompt-idx 0)

(defvar elfai--request-url-buffers nil
  "Alist of active request buffers requests.")

(defvar elfai--debug-data-raw nil
  "Stores raw data for debugging purposes.")

(defvar auth-sources)

(defun elfai-api-key-from-auth-source (&optional url)
  "Return the fist API key from the auth source for URL.
By default, the value of `elfai-gpt-url' is used as URL."
  (require 'auth-source)
  (require 'url-parse)
  (let* ((host
          (url-host (url-generic-parse-url (or url elfai-gpt-url))))
         (secret (plist-get (car (auth-source-search
                                  :host host))
                            :secret)))
    (pcase secret
      ((pred not)
       (user-error (format "No `elfai-api-key' found in the auth source.
Your auth-sources %s should contain such entry:
machine %s password TOKEN" auth-sources host)))
      ((pred functionp)
       (encode-coding-string (funcall secret) 'utf-8))
      (_ secret))))

(defun elfai-get-api-key ()
  "Return the value of `elfai-api-key' if it is a function.
If it is a string, prompt the user for a key, save it, and renturn the key.
If `elfai-api-key' is not set, raise an error."
  (pcase elfai-api-key
    ((pred functionp)
     (funcall elfai-api-key))
    ((pred stringp)
     (while (string-empty-p elfai-api-key)
       (let ((key (read-string "GPT Api Key: ")))
         (customize-set-value 'elfai-api-key key)
         (when (yes-or-no-p "Save this key?")
           (customize-save-variable 'elfai-api-key key))))
     elfai-api-key)
    (_ (error "`elfai-api-key' is not set"))))

(defun elfai--json-parse-string (str &optional object-type array-type
                                     null-object false-object)
  "Parse STR with natively compiled function or with json library.

The argument OBJECT-TYPE specifies which Lisp type is used
to represent objects; it can be `hash-table', `alist' or `plist'.  It
defaults to `alist'.

The argument ARRAY-TYPE specifies which Lisp type is used
to represent arrays; `array'/`vector' and `list'.

The argument NULL-OBJECT specifies which object to use
to represent a JSON null value.  It defaults to `:null'.

The argument FALSE-OBJECT specifies which object to use to
represent a JSON false value.  It defaults to `:false'."
  (if (and (fboundp 'json-parse-string)
           (fboundp 'json-available-p)
           (json-available-p))
      (json-parse-string str
                         :object-type (or object-type 'alist)
                         :array-type
                         (pcase array-type
                           ('list 'list)
                           ('vector 'array)
                           (_ 'array))
                         :null-object (or null-object :null)
                         :false-object (or false-object :false))
    (require 'json)
    (let ((json-object-type (or object-type 'alist))
          (json-array-type
           (pcase array-type
             ('list 'list)
             ('array 'vector)
             (_ 'vector)))
          (json-null (or null-object :null))
          (json-false (or false-object :false)))
      (json-read-from-string str))))

(defun elfai--json-read-buffer (&optional object-type array-type null-object
                                          false-object)
  "Parse json from the current buffer using specified object and array types.

The argument OBJECT-TYPE specifies which Lisp type is used
to represent objects; it can be `hash-table', `alist' or `plist'.  It
defaults to `alist'.

The argument ARRAY-TYPE specifies which Lisp type is used
to represent arrays; `array'/`vector' and `list'.

The argument NULL-OBJECT specifies which object to use
to represent a JSON null value.  It defaults to `:null'.

The argument FALSE-OBJECT specifies which object to use to
represent a JSON false value.  It defaults to `:false'."
  (if (and (fboundp 'json-parse-string)
           (fboundp 'json-available-p)
           (json-available-p))
      (json-parse-buffer
       :object-type (or object-type 'alist)
       :array-type
       (pcase array-type
         ('list 'list)
         ('vector 'array)
         (_ 'array))
       :null-object (or null-object :null)
       :false-object (or false-object :false))
    (let ((json-object-type (or object-type 'alist))
          (json-array-type
           (pcase array-type
             ('list 'list)
             ('array 'vector)
             (_ 'vector)))
          (json-null (or null-object :null))
          (json-false (or false-object :false)))
      (json-read))))

(defun elfai--abort-all ()
  "Cancel all pending GPT document requests."
  (elfai--abort-by-url-buffer t))

;;;###autoload
(defun elfai-abort-all ()
  "Terminate the process associated with a buffer BUFF and delete its buffer.

Argument BUFF is the buffer in which the process to be aborted is running."
  (interactive)
  (elfai--abort-all))

(defun elfai-restore-text-props ()
  "Restore old text properties after removing `elfai' props."
  (pcase-let* ((`(,beg . ,end)
                (elfai--property-boundaries 'elfai-old))
               (value (and beg
                           (get-text-property beg 'elfai-old))))
    (when (and beg end)
      (remove-text-properties beg end '(elfai t elfai-old t)))
    (when beg
      (goto-char beg)
      (delete-region beg end)
      (when (stringp value)
        (insert value)))))

(defun elfai-goto-char (position)
  "Jump to POSITION in all windows displaying the buffer.

Argument POSITION is the buffer position to go to."
  (goto-char position)
  (dolist (wnd (get-buffer-window-list (current-buffer) nil t))
    (set-window-point wnd position)))

(defun elfai-abort-buffer (buffer)
  "Cancel ongoing URL request for buffer.

Argument BUFFER is the buffer associated with a request to be aborted."
  (pcase-dolist (`(,req-buff . ,marker) elfai--request-url-buffers)
    (let ((buff
           (when (markerp marker)
             (marker-buffer marker))))
      (when (eq buffer buff)
        (elfai--abort-by-url-buffer req-buff)))))

(defun elfai--property-boundaries (prop &optional pos)
  "Return boundaries of property PROP at POS (cdr is 1+)."
  (unless pos (setq pos (point)))
  (let (beg end val)
    (setq val (get-text-property pos prop))
    (if (null val)
        val
      (if (or (bobp)
              (not (eq (get-text-property (1- pos) prop) val)))
          (setq beg pos)
        (setq beg (previous-single-property-change pos prop))
        (when (null beg)
          (setq beg (point-min))))
      (if (or (eobp)
              (not (eq (get-text-property (1+ pos) prop) val)))
          (setq end pos)
        (setq end (next-single-property-change pos prop))
        (when (null end)
          (setq end (point-min))))
      (cons beg end))))

(defun elfai--remove-text-props ()
  "Strip `elfai' text properties from a document region."
  (pcase-let ((`(,beg . ,end)
               (elfai--property-boundaries 'elfai)))
    (when (and beg end)
      (remove-text-properties beg end '(elfai t elfai-old t)))))

(defun elfai-abort-current-buffer ()
  "Cancel processing in the active buffer."
  (let ((buff (current-buffer)))
    (elfai-abort-buffer buff)))

(defun elfai--abort-by-url-buffer (url-buff)
  "Cancel ongoing URL fetch and close buffer.

Argument URL-BUFF is the buffer associated with the URL retrieval process to be
aborted."
  (pcase-dolist (`(,req-buff . ,marker) elfai--request-url-buffers)
    (when (or (eq url-buff t)
              (eq req-buff url-buff))
      (when (buffer-live-p req-buff)
        (let ((proc (get-buffer-process req-buff)))
          (when proc
            (delete-process proc))
          (kill-buffer req-buff))))
    (elfai--abort-by-marker marker))
  (setq elfai--request-url-buffers
        (if (eq url-buff t)
            nil
          (assq-delete-all url-buff elfai--request-url-buffers)))
  (when (symbol-value 'elfai-abort-mode)
    (elfai-abort-mode -1)))

(defun elfai--retrieve-error (status)
  "Extract and format error details from STATUS.

Argument STATUS is a plist containing the status of the HTTP request."
  (pcase-let*
      ((status-error (plist-get status :error))
       (`(_err ,type ,code) status-error)
       (description
        (and status-error
             (progn
               (when (and (boundp
                           'url-http-end-of-headers)
                          url-http-end-of-headers)
                 (goto-char url-http-end-of-headers))
               (when-let ((err (ignore-errors
                                 (cdr-safe
                                  (assq 'error
                                        (elfai--json-read-buffer
                                         'alist))))))
                 (or (cdr-safe (assq 'message err)) err))))))
    (when status-error
      (let* ((prefix (if (facep 'error)
                         (propertize
                          "elfai error"
                          'face
                          'error)
                       "elfai error"))
             (details (delq nil
                            (list
                             (when type  (format "%s request failed" type))
                             (when code (format "with status %s" code))
                             (when description (format "- %s" description))))))
        (if details
            (concat prefix ": "
                    (string-join
                     details
                     " "))
          prefix)))))

(defun elfai--get-response-content (response)
  "Retrieve and decode content from a RESPONSE object.

Argument RESPONSE is a plist containing the API response data."
  (when-let* ((choices (plist-get response
                                  :choices))
              (choice (elt choices 0))
              (delta (plist-get choice :delta))
              (content (plist-get delta :content)))
    (decode-coding-string content 'utf-8)))



(defun elfai--insert-with-delay (text)
  "Insert each character of TEXT with a random delay up to 0.3 seconds.

Argument TEXT is the string to be inserted character by character."
  (let* ((parts (split-string text "[\s\t]" nil)))
    (condition-case nil
        (while parts
          (insert (car parts) " ")
          (run-hooks 'post-command-hook)
          (setq parts (cdr parts))
          (sit-for (/ (float (random 2)) 10)))
      (quit (insert (string-join (reverse parts) " "))))))

(defun elfai--stream-insert-response (response info)
  "Insert and format RESPONSE text at a marker.

Argument RESPONSE is a string containing the server's response.

Argument INFO is a property list containing the insertion position and tracking
information."
  (let ((start-marker (plist-get info :position))
        (tracking-marker (plist-get info :tracking-marker))
        (inserter (plist-get info :inserter)))
    (when response
      (with-current-buffer (marker-buffer start-marker)
        (save-excursion
          (unless tracking-marker
            (goto-char start-marker)
            (setq tracking-marker (set-marker (make-marker) (point)))
            (set-marker-insertion-type tracking-marker t)
            (plist-put info :tracking-marker tracking-marker))
          (goto-char tracking-marker)
          (add-text-properties
           0 (length response) elfai-props-indicator
           response)
          (funcall (or inserter #'insert) response)
          (run-hooks 'post-command-hook)
          (run-hooks 'elfai--stream-after-insert-hook))))))



(defun elfai--abort-by-marker (marker)
  "Restore text properties and clean up after aborting a request.

Argument MARKER is a marker object indicating the position in the buffer where
the text properties should be restored."
  (let ((buff
         (when (markerp marker)
           (marker-buffer marker))))
    (when (buffer-live-p buff)
      (with-current-buffer buff
        (save-excursion
          (elfai-goto-char marker)
          (elfai-restore-text-props))))
    (when-let ((cell (rassq marker elfai--request-url-buffers)))
      (setcdr cell nil))))

(defun elfai--parse-request-chunks (info)
  "Parse and insert GPT-generated Emacs Lisp documentation.

Argument INFO is a property list containing various request-related data."
  (let ((request-buffer (plist-get info :request-buffer))
        (request-marker (plist-get info :request-marker))
        (buffer (plist-get info :buffer))
        (callback (plist-get info :callback)))
    (when request-buffer
      (with-current-buffer request-buffer
        (when (and (boundp 'url-http-end-of-headers)
                   url-http-end-of-headers)
          (save-match-data
            (save-excursion
              (if request-marker
                  (goto-char request-marker)
                (goto-char url-http-end-of-headers)
                (setq request-marker (point-marker))
                (plist-put info :request-marker request-marker))
              (unless (eolp)
                (beginning-of-line))
              (let ((errored nil))
                (when elfai-debug
                  (setq elfai--debug-data-raw
                        (append elfai--debug-data-raw
                                (list
                                 (list
                                  (buffer-substring-no-properties
                                   (point-min)
                                   (point-max))
                                  (point))))))
                (while (and (not errored)
                            (search-forward "data: " nil t))
                  (let* ((line
                          (buffer-substring-no-properties
                           (point)
                           (line-end-position))))
                    (if (string= line "[DONE]")
                        (progn
                          (when (and (not (plist-get info :done))
                                     (buffer-live-p buffer))
                            (plist-put info :done t)
                            (let ((tracking-marker
                                   (plist-get info
                                              :tracking-marker))
                                  (final-callback
                                   (plist-get info
                                              :final-callback))
                                  (start-marker
                                   (plist-get info
                                              :position)))
                              (with-current-buffer buffer
                                (let* ((beg
                                        (when start-marker
                                          (marker-position start-marker)))
                                       (end
                                        (when tracking-marker
                                          (marker-position tracking-marker)))
                                       (len (and beg end (- end beg))))
                                  (save-excursion
                                    (run-hook-with-args 'after-change-functions
                                                        beg beg len)
                                    (syntax-ppss-flush-cache beg)
                                    (when tracking-marker
                                      (goto-char tracking-marker))
                                    (when final-callback
                                      (funcall final-callback))
                                    (when start-marker
                                      (goto-char start-marker))
                                    (unless (symbol-value 'elfai-mode)
                                      (elfai--remove-text-props))))
                                (setq elfai--request-url-buffers
                                      (assq-delete-all
                                       (plist-get info :request-buffer)
                                       elfai--request-url-buffers))
                                (when (symbol-value 'elfai-abort-mode)
                                  (elfai-abort-mode -1)))))
                          (set-marker
                           request-marker
                           (point)))
                      (condition-case _err
                          (let* ((data (elfai--json-parse-string
                                        line 'plist))
                                 (err (plist-get data :error)))
                            (end-of-line)
                            (set-marker
                             request-marker
                             (point))
                            (if err
                                (progn
                                  (setq errored t)
                                  (when err
                                    (message "elfai-error: %s"
                                             (or
                                              (plist-get err
                                                         :message)
                                              err))))
                              (when callback
                                (funcall
                                 callback
                                 data))))
                        (error
                         (setq errored t)
                         (goto-char
                          request-marker))))))))))))))

(defun elfai--plist-merge (plist-a plist-b)
  "Add props from PLIST-B to PLIST-A."
  (dotimes (idx (length plist-b))
    (when (eq (logand idx 1) 0)
      (let ((prop-name (nth idx plist-b)))
        (let ((val (plist-get plist-b prop-name)))
          (plist-put plist-a prop-name val)))))
  plist-a)

(defun elfai--plist-pick (props plist)
  "Pick PROPS from PLIST."
  (let ((result '()))
    (dolist (prop props result)
      (when (plist-member plist prop)
        (setq result (plist-put result prop (plist-get plist prop)))))))

(defun elfai--plist-omit (keys plist)
  "Remove specified KEYS from PLIST and return the result.

Argument KEYS is a list of keys to omit from PLIST.

Argument PLIST is the property list from which KEYS are omitted."
  (let (result)
    (dotimes (idx (length plist))
      (when (eq (logand idx 1) 0)
        (let ((key (nth idx plist)))
          (unless (member key keys)
            (setq result (plist-put result key (nth (1+ idx) plist)))))))
    result))

(defun elfai--stream-request (request-data &optional final-callback buffer
                                           position &rest props)
  "Send a POST request with JSON data and handle the response.

Argument REQUEST-DATA is a JSON object containing the request data.

Optional argument FINAL-CALLBACK is a function called with the response data.

Optional argument BUFFER is the buffer to use for the request and response. It
defaults to the current buffer.

Optional argument POSITION is the position in the BUFFER where the response
should be inserted. It can be a marker or an integer.

Remaining arguments PROPS are additional properties passed as a plist."
  (require 'json)
  (let* ((buffer (or buffer (current-buffer)))
         (start-marker
          (cond ((not position)
                 (point-marker))
                ((markerp position) position)
                ((integerp position)
                 (set-marker (make-marker) position buffer))))
         (info (elfai--plist-merge (list
                                    :buffer buffer
                                    :final-callback final-callback
                                    :position start-marker)
                                   props))
         (error-cb (plist-get info :error-callback))
         (url-request-extra-headers `(("Authorization" .
                                       ,(encode-coding-string
                                         (string-join
                                          `("Bearer"
                                            ,(elfai-get-api-key))
                                          " ")
                                         'utf-8))
                                      ("Content-Type" . "application/json")))
         (url-request-method "POST")
         (url-request-data (encode-coding-string
                            (json-encode
                             request-data)
                            'utf-8))
         (request-buffer)
         (callback
          (lambda (response)
            (let ((err (plist-get response :error)))
              (if err
                  (progn
                    (let ((msg (or
                                (plist-get err
                                           :message)
                                (format "%s" err))))
                      (message "elfai-callback err %s" msg)
                      (when (buffer-live-p buffer)
                        (when error-cb
                          (with-current-buffer buffer
                            (when error-cb
                              (funcall error-cb err))))
                        (let ((start-marker
                               (plist-get info
                                          :position)))
                          (elfai--abort-by-marker start-marker)))))
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (elfai--stream-insert-response
                     (elfai--get-response-content
                      response)
                     info))))))))
    (plist-put info :callback callback)
    (setq request-buffer
          (url-retrieve
           elfai-gpt-url
           (lambda (status &rest _events)
             (let* ((buff (current-buffer))
                    (err
                     (elfai--retrieve-error status)))
               (if (not err)
                   (when (symbol-value 'elfai-abort-mode)
                     (elfai-abort-mode -1))
                 (run-with-timer 0.5 nil #'elfai--abort-by-url-buffer buff)
                 (message err)
                 (when (buffer-live-p buffer)
                   (when (and error-cb (buffer-live-p buffer))
                     (with-current-buffer buffer
                       (when error-cb
                         (funcall error-cb err))))
                   (let ((start-marker
                          (plist-get info
                                     :position)))
                     (elfai--abort-by-marker start-marker))))))))
    (plist-put info :request-buffer request-buffer)
    (push (cons request-buffer start-marker)
          elfai--request-url-buffers)
    (with-current-buffer buffer
      (elfai-abort-mode 1)
      (add-hook 'kill-buffer-hook #'elfai-abort-current-buffer nil t))
    (with-current-buffer request-buffer
      (add-hook 'after-change-functions
                (lambda (&rest _)
                  (elfai--parse-request-chunks info))
                nil t))))

(defun elfai-stream (system-prompt user-prompt &optional final-callback buffer
                                   position &rest props)
  "Send GPT stream request with USER-PROMPT and SYSTEM-PROMPT.

Argument SYSTEM-PROMPT is a string representing the system's part of the
conversation.

Argument USER-PROMPT is a string representing the user's part of the
conversation.

Optional argument FINAL-CALLBACK is a function to be called when the request is
completed.

Optional argument BUFFER is the buffer where the output should be inserted. It
defaults to the current buffer.

Optional argument POSITION is the position in the BUFFER where the output should
be inserted. It can be a marker, an integer, or nil. If nil, the current point
or region end is used.

Remaining arguments PROPS are additional properties passed as a plist."
  (let ((messages (apply #'vector `((:role "system"
                                     :content ,(or
                                                system-prompt
                                                ""))
                                    (:role "user"
                                     :content ,user-prompt)))))
    (apply #'elfai--stream-request
           (elfai--plist-merge (list
                                :messages messages
                                :model elfai-gpt-model
                                :temperature
                                elfai-gpt-temperature
                                :stream t)
                               (elfai--plist-pick
                                '(:model
                                  :temperature)
                                props))
           final-callback buffer
           position
           (elfai--plist-omit
            '(:model
              :temperature)
            props))))

(defvar-local elfai--bus nil
  "Local variable holding the event bus instance.")

(defun elfai-command-watcher ()
  "Monitor `keyboard-quit' commands and handle GPT documentation aborts."
  (cond ((and elfai--request-url-buffers
              (eq this-command 'keyboard-quit))
         (push this-command elfai--bus)
         (let ((len (length elfai--bus)))
           (cond ((>= len elfai-abort-on-keyboard-quit-count)
                  (message  "elfai: Aborting")
                  (setq elfai--bus nil)
                  (elfai-abort-all)
                  (elfai--update-status " Aborted" 'error))
                 ((< len elfai-abort-on-keyboard-quit-count)
                  (message
                   (substitute-command-keys
                    "elfai: Press `\\[keyboard-quit]' %d more times to force interruption.")
                   (- elfai-abort-on-keyboard-quit-count len))))))
        (elfai--bus (setq elfai--bus nil))))

;;;###autoload
(defun elfai-ask-and-insert (str)
  "Prompt user for input and send it to GPT for processing.

Argument STR is a string to be inserted."
  (interactive (list (read-string "Ask: ")))
  (elfai-stream nil str))

(defun elfai--get-content-with-cursor (placeholder &optional beg end)
  "Return buffer string with cursor position as PLACEHOLDER.

Argument PLACEHOLDER is a string to be replaced in the content.

Optional argument BEG is the beginning position in the buffer from which to
extract content. It defaults to the beginning of the buffer.

Optional argument END is the ending position in the buffer up to which to
extract content. It defaults to the END of the buffer."
  (unless beg (setq beg (point-min)))
  (unless end (setq end (point-max)))
  (let* ((pos (max (1+ (- (point) beg))
                   (point-min)))
         (orig-content (buffer-substring-no-properties (or beg (point-min))
                                                       (or end (point-max)))))
    (with-temp-buffer
      (insert (replace-regexp-in-string
               (regexp-quote placeholder)
               (make-string
                (length
                 placeholder)
                ?\*)
               orig-content))
      (goto-char pos)
      (insert placeholder)
      (buffer-substring-no-properties (point-min)
                                      (point-max)))))


;;;###autoload
(defun elfai-complete-here (&optional partial-content)
  "Replace placeholder text in a buffer with GPT-generated content.

Optional argument PARTIAL-CONTENT is a boolean indicating whether to use only
the part of the buffer before the point."
  (interactive "P")
  (let ((gpt-content (elfai--get-content-with-cursor
                      (car elfai-complete-prompt)
                      (point-min)
                      (if partial-content
                          (point)
                        (point-max))))
        (prompt
         (cdr elfai-complete-prompt)))
    (elfai--debug gpt-content)
    (elfai-stream prompt gpt-content)))

;;;###autoload
(defun elfai-complete-with-partial-context ()
  "Invoke GPT completion with partial buffer context."
  (interactive)
  (elfai-complete-here t))


(defun elfai--format-plural (count singular-str)
  "Format COUNT with SINGULAR-STR, adding \"s\" for plural.

Argument COUNT is an integer representing the quantity to consider for
pluralization.

Argument SINGULAR-STR is a string representing the singular form of the word to
be potentially pluralized."
  (concat (format "%d " count)
          (concat singular-str
                  (if (= count 1) "" "s"))))

(defun elfai--format-time-diff (time)
  "Format a human-readable string representing TIME difference.

Argument TIME is a time value representing the number of seconds since the epoch
\\=(January 1, 1970, 00:00:00 GMT)."
  (let ((diff-secs
         (- (float-time (encode-time (append (list 0)
                                             (cdr (decode-time
                                                   (current-time))))))
            (float-time
             (encode-time (append (list 0)
                                  (cdr (decode-time time))))))))
    (if (zerop (round diff-secs))
        "Now"
      (let* ((past (> diff-secs 0))
             (diff-secs-int (if past diff-secs (- diff-secs)))
             (suffix (if past "ago" "from now"))
             (minutes-secs 60)
             (hours-secs (* 60 minutes-secs))
             (day-secs (* 24 hours-secs))
             (month-secs (* 30 day-secs))
             (year-secs (* 365 day-secs))
             (res
              (cond ((< diff-secs-int minutes-secs)
                     (elfai--format-plural (truncate diff-secs-int)
                                           "second"))
                    ((< diff-secs-int hours-secs)
                     (elfai--format-plural (truncate (/ diff-secs-int
                                                        minutes-secs))
                                           "minute"))
                    ((< diff-secs-int day-secs)
                     (elfai--format-plural (truncate
                                            (/ diff-secs-int
                                               hours-secs))
                                           "hour"))
                    ((< diff-secs-int month-secs)
                     (elfai--format-plural (truncate (/ diff-secs-int
                                                        day-secs))
                                           "day"))
                    ((< diff-secs-int year-secs)
                     (elfai--format-plural (truncate
                                            (/ diff-secs-int
                                               month-secs))
                                           "month"))
                    (t
                     (let* ((months (truncate (/ diff-secs-int month-secs)))
                            (years (/ months 12))
                            (remaining-months (% months 12)))
                       (string-join
                        (delq nil
                              (list
                               (when (> years 0)
                                 (elfai--format-plural years "year"))
                               (when (> remaining-months 0)
                                 (elfai--format-plural
                                  remaining-months "month"))))
                        " "))))))
        (concat res " " suffix)))))

(defvar elfai-models-sorted nil
  "Sorted list of open AI models.")

(defun elfai--plist-remove-nils (plist)
  "Remove nil values from a property list.

Argument PLIST is a property list from which nil values are to be removed."
  (let* ((result (list 'head))
         (last result))
    (while plist
      (let* ((key (pop plist))
             (val (pop plist))
             (new (and val (list key val))))
        (when new
          (setcdr last new)
          (setq last (cdr new)))))
    (cdr result)))

(defun elfai--download-image (url &optional filename on-success on-error
                                  finally)
  "Download an image from URL and save it as FILENAME, handling success or error.

Argument URL is the location of the image to download.

Optional argument FILENAME is the name of the file where the image will be
saved. If not provided, a temporary file is created.

Optional argument ON-SUCCESS is a function called with FILENAME as an argument
if the image is downloaded successfully.

Optional argument ON-ERROR is a function called with an error message if the
download fails. It defaults to `minibuffer-message'.

Optional argument FINALLY is a function called after the download attempt,
regardless of its success or failure."
  (url-retrieve url
                (lambda (status file &rest _)
                  (unless file (setq file
                                     (expand-file-name
                                      (concat "elfai-"
                                              (format-time-string
                                               elfai-image-time-format)
                                              ".png")
                                      (cond ((eq
                                              elfai-images-dir
                                              'read-directory-name)
                                             (read-directory-name
                                              "Directory to save image: "))
                                            ((functionp
                                              elfai-images-dir)
                                             (funcall elfai-images-dir))
                                            (t
                                             elfai-images-dir)))))
                  (unless (file-exists-p (file-name-directory file))
                    (make-directory (file-name-directory file)
                                    'parents))
                  (unwind-protect
                      (if-let ((err (elfai--retrieve-error status)))
                          (funcall (or on-error #'minibuffer-message) err)
                        (delete-region
                         (point-min)
                         (progn
                           (re-search-forward "\n\n" nil 'move)
                           (point)))
                        (let ((coding-system-for-write 'no-conversion))
                          (write-region nil nil file nil nil nil nil))
                        (when on-success
                          (funcall on-success file)))
                    (when finally (funcall finally))))
                (list
                 filename)
                nil t))

(defun elfai--download-images (urls &optional callback results)
  "Download images from URLS asynchronously, optionally calling a callback.

Argument URLS is a list of strings, each representing a URL to download an image
from.

Optional argument CALLBACK is a function to be called once all images have been
downloaded.

Optional argument RESULTS is a list to accumulate the downloaded image file
paths."
  (let ((next-url (pop urls)))
    (if next-url
        (elfai--download-image
         next-url
         nil
         (lambda (file)
           (setq results (push file results)))
         nil
         (lambda ()
           (if urls
               (elfai--download-images urls callback results)
             (when callback (funcall callback results)))))
      (when callback
        (funcall callback results)))))

;;;###autoload
(defun elfai-create-image (prompt &optional model size style callback)
  "Generate an image based on a PROMPT using OpenAI's API.

Argument PROMPT is a string that describes the image to be created.

Optional argument MODEL is a string specifying the model to use for image
generation. It defaults to \"dall-e-3\".

Optional argument SIZE is a string indicating the size of the generated image.
The image generations endpoint allows you to create an original image given a
text prompt. When using DALL·E 3, images can have a size of 1024x1024, 1024x1792
or 1792x1024 pixels.

Optional argument STYLE is a string specifying the style of the generated image.

By default, images are generated at standard quality, but when using DALL·E 3
you can set quality: \"hd\" for enhanced detail. Square, standard quality images
are the fastest to generate.

Optional argument CALLBACK is a function to be called with the result of the
image generation."
  (interactive
   (let* ((prompt (read-string "Prompt:"
                               (when (and (region-active-p)
                                          (use-region-p))
                                 (buffer-substring-no-properties
                                  (region-beginning)
                                  (region-end)))))
          (model "dall-e-3"))
     (list prompt
           model
           (car
            (pcase model
              ("dall-e-3" '("1024x1024" "1792x1024" "1024x1792"))
              (_ '("256x256","512x512" "1024x1024"))))
           (pcase model
             ("dall-e-3" "vivid")))))
  (let ((url "https://api.openai.com/v1/images/generations")
        (api-key (elfai-get-api-key)))
    (let* ((url-request-method "POST")
           (url-request-extra-headers
            `(("Content-Type" . "application/json")
              ("Authorization" . ,(format "Bearer %s"
                                   api-key))))
           (url-request-data (encode-coding-string
                              (json-encode
                               (elfai--plist-remove-nils
                                (list
                                 :prompt prompt
                                 :model model
                                 :size size
                                 :style style
                                 :quality
                                 (pcase model
                                   ("dall-e-3"
                                    "hd")))))
                              'utf-8)))
      (url-retrieve url #'elfai--fetched-images-callback (list
                                                          callback)))))

(defun elfai--fetched-images-callback (status callback &rest _)
  "Fetch images from URLs and process them with a callback.

Argument STATUS is a plist containing the status of the HTTP request.

Argument CALLBACK is a function to be called with the fetched images."
  (if-let ((err
            (elfai--retrieve-error
             status)))
      (minibuffer-message err)
    (goto-char url-http-end-of-headers)
    (let* ((response
            (elfai--json-read-buffer 'alist
                                     'list))
           (urls (mapcar (apply-partially #'alist-get
                                          'url)
                         (alist-get 'data
                                    response))))
      (elfai--download-images urls
                              (lambda (files)
                                (if (functionp callback)
                                    (funcall callback files)
                                  (message
                                   (format
                                    "Fetched %s"
                                    (string-join
                                     files
                                     ",\s")))))))))

;;;###autoload
(defun elfai-generate-images-batch (prompt &optional count)
  "Generate a batch of images based on a PROMPT and count.

Argument PROMPT is a string used as the input prompt for generating images.

Optional argument COUNT is the number of images to generate; it defaults to 1."
  (interactive (list (or (read-string "Prompt: "
                                      (when (and (region-active-p)
                                                 (use-region-p))
                                        (buffer-substring-no-properties
                                         (region-beginning)
                                         (region-end)))))
                     (read-number "Number: ")))
  (message "Generating %s images" count)
  (elfai-create-image
   prompt
   "dall-e-3" "1024x1024"
   "vivid"
   (lambda (files)
     (message "Created images %s" files)
     (if (not count)
         (elfai-generate-images-batch prompt 10)
       (if (> count 0)
           (run-with-idle-timer 2 nil #'elfai-generate-images-batch
                                prompt
                                (1-
                                 count))
         (message "Finished generation of images"))))))

;;;###autoload
(defun elfai-create-image-variation (image-file &optional size callback)
  "Create variations of an image by uploading and processing it via OpenAI API.

Argument IMAGE-FILE is the path to the image file to upload.

Optional argument SIZE specifies the desired size for the image variation; it
defaults to \"1024x1024\".

Optional argument CALLBACK is a function to be called with the result."
  (interactive (list (elfai--read-image-from-multi-sources)
                     (completing-read "Size: "
                                      '("256x256" "512x512" "1024x1024"))))
  (let ((boundary "----WebKitFormBoundary7MA4YWxkTrZu0gW")
        (url "https://api.openai.com/v1/images/variations")
        (api-key (elfai-get-api-key)))
    ;; Prepare the payload
    (let* ((image-data
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally image-file)
              (buffer-string)))
           (url-request-method "POST")
           (url-request-extra-headers
            `(("Content-Type" . ,(concat "multipart/form-data; boundary="
                                  boundary))
              ("Authorization" . ,(concat "Bearer " api-key))))
           (url-request-data
            (encode-coding-string
             (concat
              "--" boundary "\r\n"
              "Content-Disposition: form-data; name=\"image\"; filename=\""
              (file-name-nondirectory
               image-file)
              "\"\r\n"
              "Content-Type: image/png\r\n\r\n"
              image-data "\r\n"
              "--" boundary "\r\n"
              "Content-Disposition: form-data; name=\"n\"\r\n\r\n"
              "1\r\n"
              "--" boundary "\r\n"
              "Content-Disposition: form-data; name=\"size\"\r\n\r\n"
              (or size "1024x1024")
              "\r\n"
              "--" boundary "--")
             'binary)))
      (url-retrieve url #'elfai--fetched-images-callback
                    (list callback)))))

(defun elfai--encode-image (image-path)
  "Encode the image at IMAGE-PATH to a base64 data URI."
  (with-temp-buffer
    (insert-file-contents-literally image-path)
    (base64-encode-region (point-min)
                          (point-max) t)
    (concat "data:image/jpeg;base64," (buffer-string))))

(defun elfai--minibuffer-get-metadata ()
  "Return current minibuffer completion metadata."
  (completion-metadata
   (buffer-substring-no-properties
    (minibuffer-prompt-end)
    (max (minibuffer-prompt-end)
         (point)))
   minibuffer-completion-table
   minibuffer-completion-predicate))

(defun elfai--minibuffer-ivy-selected-cand ()
  "Return the currently selected item in Ivy."
  (when (and (memq 'ivy--queue-exhibit post-command-hook)
             (boundp 'ivy-text)
             (boundp 'ivy--length)
             (boundp 'ivy-last)
             (fboundp 'ivy--expand-file-name)
             (fboundp 'ivy-state-current))
    (cons
     (completion-metadata-get (ignore-errors (elfai--minibuffer-get-metadata))
                              'category)
     (ivy--expand-file-name
      (if (and (> ivy--length 0)
               (stringp (ivy-state-current ivy-last)))
          (ivy-state-current ivy-last)
        ivy-text)))))

(defun elfai--minibuffer-get-default-candidates ()
  "Return all current completion candidates from the minibuffer."
  (when (minibufferp)
    (let* ((all (completion-all-completions
                 (minibuffer-contents)
                 minibuffer-completion-table
                 minibuffer-completion-predicate
                 (max 0 (- (point)
                           (minibuffer-prompt-end)))))
           (last (last all)))
      (when last (setcdr last nil))
      (cons
       (completion-metadata-get (elfai--minibuffer-get-metadata) 'category)
       all))))

;; (defun elfai--org-inline-data-image (_protocol link _description)
;;   "Interpret LINK as base64-encoded image data."
;;   (base64-decode-string link))
;; (require 'org)

;; (org-link-set-parameters
;;  "img"
;;  :image-data-fun #'elfai--org-inline-data-image)

(defun elfai--get-minibuffer-get-default-completion ()
  "Target the top completion candidate in the minibuffer.
Return the category metadatum as the type of the target."
  (when (and (minibufferp) minibuffer-completion-table)
    (pcase-let* ((`(,category . ,candidates)
                  (elfai--minibuffer-get-default-candidates))
                 (contents (minibuffer-contents))
                 (top (if (test-completion contents
                                           minibuffer-completion-table
                                           minibuffer-completion-predicate)
                          contents
                        (let ((completions (completion-all-sorted-completions)))
                          (if (null completions)
                              contents
                            (concat
                             (substring contents
                                        0 (or (cdr (last completions)) 0))
                             (car completions)))))))
      (cons category (or (car (member top candidates)) top)))))

(defvar elfai--minibuffer-targets-finders
  '(elfai--minibuffer-ivy-selected-cand
    elfai--get-minibuffer-get-default-completion))

(defun elfai--minibuffer-get-current-candidate ()
  "Return cons filename for current completion candidate."
  (let (target)
    (run-hook-wrapped
     'elfai--minibuffer-targets-finders
     (lambda (fun)
       (when-let ((result (funcall fun)))
         (when (and (cdr-safe result)
                    (stringp (cdr-safe result))
                    (not (string-empty-p (cdr-safe result))))
           (setq target result)))
       (and target (minibufferp))))
    target))

(defun elfai--minibuffer-exit-with-action (action)
  "Call ACTION with current candidate and exit minibuffer."
  (pcase-let ((`(,_category . ,current)
               (elfai--minibuffer-get-current-candidate)))
    (progn (run-with-timer 0.1 nil action current)
           (abort-minibuffers))))

(defun elfai--minibuffer-action-no-exit (action)
  "Call ACTION with minibuffer candidate in its original window."
  (pcase-let ((`(,_category . ,current)
               (elfai--minibuffer-get-current-candidate)))
    (with-minibuffer-selected-window
      (funcall action current))))

(defun elfai--completing-read-with-preview (prompt collection &optional
                                                   preview-action keymap
                                                   predicate require-match
                                                   initial-input hist def
                                                   inherit-input-method)
  "Read COLLECTION in minibuffer with PROMPT and KEYMAP.
See `completing-read' for PREDICATE REQUIRE-MATCH INITIAL-INPUT HIST DEF
INHERIT-INPUT-METHOD."
  (let ((collection (if (stringp (car-safe collection))
                        (copy-tree collection)
                      collection))
        (timer))
    (minibuffer-with-setup-hook
        (lambda ()
          (when (minibufferp)
            (when keymap
              (let ((map (make-composed-keymap keymap
                                               (current-local-map))))
                (use-local-map map)))
            (when preview-action
              (when-let ((after-change-fn
                          (pcase elfai-image-auto-preview-enabled
                            ((pred numberp)
                             (lambda (&rest _)
                               (when (timerp timer)
                                 (cancel-timer timer))
                               (setq timer
                                     (run-with-idle-timer
                                      elfai-image-auto-preview-enabled
                                      nil
                                      (lambda
                                        (buff action)
                                        (when
                                            (buffer-live-p
                                             buff)
                                          (with-current-buffer
                                              buff
                                            (elfai--minibuffer-action-no-exit
                                             action))))
                                      (current-buffer)
                                      preview-action))))
                            ('t (lambda (&rest _)
                                  (elfai--minibuffer-action-no-exit
                                   preview-action))))))
                (add-hook 'after-change-functions after-change-fn nil t)))))
      (completing-read prompt
                       collection
                       predicate
                       require-match initial-input hist
                       def inherit-input-method))))

(defun elfai--get-active-directories ()
  "Return directories of buffers displayed in windows, prioritizing current."
  (let* ((curr-buf (current-buffer))
         (live-buffers (seq-sort-by (lambda (it)
                                      (if (get-buffer-window it)
                                          (if (eq curr-buf it)
                                              1
                                            2)
                                        -1))
                                    #'>
                                    (buffer-list))))
    (delete-dups
     (delq nil (mapcar (lambda (buff)
                         (when-let ((dir (buffer-local-value
                                          'default-directory
                                          buff)))
                           (when (and
                                  (not (file-remote-p dir))
                                  (file-accessible-directory-p dir))
                             (expand-file-name dir))))
                       live-buffers)))))

(defun elfai--minibuffer-preview-file-action (file)
  "Preview a FILE in the minibuffer if conditions are met.

Argument FILE is the path to the file to preview."
  (when (and file
             (file-exists-p file)
             (file-readable-p file)
             (not (file-directory-p file))
             (not
              (and large-file-warning-threshold
                   (let ((size
                          (file-attribute-size
                           (file-attributes
                            (file-truename file)))))
                     (and size
                          (> size
                             large-file-warning-threshold)
                          (message
                           "File is too large (%s) for preview "
                           size))))))
    (if-let ((buff (get-file-buffer
                    file)))
        (unless (get-buffer-window
                 buff)
          (with-selected-window
              (let ((wind
                     (selected-window)))
                (or
                 (window-right wind)
                 (window-left wind)
                 (split-window-sensibly) wind))
            (pop-to-buffer-same-window buff)))
      (with-selected-window
          (let ((wind
                 (selected-window)))
            (or
             (window-right
              wind)
             (window-left
              wind)
             (split-window-sensibly)
             wind))
        (find-file file)))))

(defun elfai--preview-minibuffer-file ()
  "Preview a file from the minibuffer without exiting."
  (interactive)
  (elfai--minibuffer-action-no-exit
   #'elfai--minibuffer-preview-file-action))

(defun elfai--files-to-sorted-alist (files)
  "Sort FILES by modification time and return as reversed alist.

Argument FILES is a list of file names to process."
  (nreverse (seq-sort-by
             (pcase-lambda (`(,_k . ,v)) v)
             #'time-less-p
             (mapcar
              (lambda (file)
                (cons
                 (abbreviate-file-name file)
                 (file-attribute-modification-time
                  (file-attributes
                   file))))
              files))))

(defun elfai--lines-from-process (program &rest args)
  "Return a completion table for output lines from PROGRAM run with ARGS."
  (let ((last-pt 1) lines)
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata (async ,program ,@args)
            (category lines-from-process))
        (with-current-buffer "*async-completing-read*"
          (when (> (point-max) last-pt)
            (setq lines
                  (append lines
                          (split-string
                           (let ((new-pt (point-max)))
                             (prog1
                                 (buffer-substring last-pt new-pt)
                               (setq last-pt new-pt)))
                           "\n" 'omit-nulls)))))
        (complete-with-action action lines string pred)))))


(defun elfai--fdfind-completing-read (&optional prompt)
  "Search files asynchronously with completion and preview.

Argument PROMPT is a string displayed as the prompt in the minibuffer."
  (let ((default-directory (expand-file-name "~/")))
    (let* ((output-buffer "*async-completing-read*")
           (fdfind-program (or (executable-find "fd")
                               (executable-find "fdfind")))
           (args (if fdfind-program
                     (list "--color=never" "-e" "png" "-E" "node_modules")
                   (list "-type" "f" "-name" (prin1-to-string "*.png"))))
           (last-pt 1)
           (lines)
           (alist)
           (annotf
            (lambda (file)
              (concat (propertize " " 'display (list 'space :align-to 120))
                      (elfai--format-time-diff (cdr (assoc-string file
                                                                  alist))))))
           (category 'file)
           (update-fn
            (lambda ()
              (when-let ((mini (active-minibuffer-window)))
                (with-selected-window mini
                  (insert "@")
                  (call-interactively #'backward-delete-char)
                  (pcase completing-read-function
                    ('ivy-completing-read
                     (when (and (fboundp 'ivy-update-candidates))
                       (ivy-update-candidates (mapcar #'car alist))))
                    ((guard (bound-and-true-p icomplete-mode))
                     (when (and (bound-and-true-p icomplete-mode)
                                (fboundp 'icomplete-exhibit))
                       (icomplete-exhibit)))
                    ('completing-read-default
                     (unless (get-buffer-window "*Completions*")
                       (when lines
                         (minibuffer-completion-help))))
                    (_
                     (completion--flush-all-sorted-completions)))))))
           (update-timer (run-with-timer
                          0.3
                          0.3
                          update-fn)))
      (unwind-protect
          (progn
            (apply
             #'start-process "*async-completing-read*" output-buffer
             (or
              fdfind-program
              "find")
             args)
            (elfai--completing-read-with-preview
             (or prompt "Image: ")
             (lambda (string pred action)
               (if (eq action 'metadata)
                   `(metadata
                     (annotation-function
                      .
                      ,annotf)
                     (category . ,category))
                 (with-current-buffer
                     "*async-completing-read*"
                   (when (> (point-max)
                            last-pt)
                     (setq lines
                           (append lines
                                   (split-string
                                    (let ((new-pt (point-max)))
                                      (prog1
                                          (buffer-substring last-pt new-pt)
                                        (setq last-pt new-pt)))
                                    "\n" 'omit-nulls)))
                     (setq alist (elfai--files-to-sorted-alist
                                  (mapcar
                                   (lambda (line) (concat "~/" line))
                                   lines)))))
                 (complete-with-action
                  action
                  alist
                  string
                  pred)))
             #'elfai--minibuffer-preview-file-action))
        (when update-timer (cancel-timer update-timer))
        (kill-buffer output-buffer)))))

(defun elfai--fdfind-all-png-files ()
  "Search for all PNG files in the home directory, excluding \"node_modules\"."
  (let ((default-directory (expand-file-name "~/")))
    (mapcar #'expand-file-name
            (with-temp-buffer
              (let ((status
                     (call-process
                      (or (executable-find "fd")
                          (executable-find "fdfind"))
                      nil t nil "-e" "png" "-E" "node_modules")))
                (if (zerop status)
                    (split-string (buffer-string) "\n" t)
                  nil))))))

(defun elfai--completing-read-all-images ()
  "List and preview all PNG files with modification times for selection."
  (let* ((files (elfai--files-to-sorted-alist
                 (elfai--fdfind-all-png-files)))
         (annotf
          (lambda (file)
            (concat (propertize " " 'display (list 'space :align-to 80))
                    (elfai--format-time-diff (cdr (assoc-string file
                                                                files))))))
         (category 'file))
    (elfai--completing-read-with-preview "Image: "
                                         (lambda (str pred action)
                                           (if (eq action 'metadata)
                                               `(metadata
                                                 (annotation-function . ,annotf)
                                                 (category . ,category))
                                             (complete-with-action action files
                                                                   str pred)))
                                         #'elfai--minibuffer-preview-file-action)))

(defun elfai--completing-read-image ()
  "Choose an image file with completion and preview."
  (let* ((dirs (elfai--get-active-directories))
         (files (elfai--files-to-sorted-alist
                 (mapcan
                  (lambda (dir)
                    (directory-files dir t
                                     "\\.png\\'"))
                  (if (member (expand-file-name elfai-images-dir) dirs)
                      dirs
                    (nconc dirs (list elfai-images-dir))))))
         (annotf
          (lambda (file)
            (concat (propertize " " 'display (list 'space :align-to 80))
                    (elfai--format-time-diff (cdr (assoc-string file
                                                                files))))))
         (category 'file))
    (elfai--completing-read-with-preview "Image: "
                                         (lambda (str pred action)
                                           (if (eq action 'metadata)
                                               `(metadata
                                                 (annotation-function . ,annotf)
                                                 (category . ,category))
                                             (complete-with-action action files
                                                                   str pred)))
                                         #'elfai--minibuffer-preview-file-action)))

(defun elfai--read-image-from-multi-sources ()
  "Choose a PNG image from multiple sources with minibuffer completion."
  (elfai--completing-read-from-multi-source
   '((elfai--completing-read-image)
     (elfai--read-image-file-name)
     (elfai--fdfind-completing-read))))

(defun elfai--read-image-file-name ()
  "Prompt user to select a PNG image file."
  (elfai--read-file-name "Image: " nil nil nil nil
                         (lambda (file)
                           (or (file-directory-p file)
                               (member (file-name-extension file)
                                       '("png"))))))

(defvar elfai--multi-source-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C->") #'elfai--source-select-next)
    (define-key map (kbd "C-j") #'elfai--preview-minibuffer-file)
    (define-key map (kbd "C-<") #'elfai--multi-source-select-prev)
    map)
  "Keymap to use in minibuffer.")

(defun elfai--completing-read-from-multi-source (sources)
  "Choose from multiple SOURCES with minibuffer completion.

Argument SOURCES is a list where each element is a list whose first element is a
function that takes any number of arguments, and the remaining elements are the
arguments to that function."
  (let ((idx 0)
        (curr))
    (while
        (let ((source-idx
               (catch 'next
                 (minibuffer-with-setup-hook
                     (lambda ()
                       (use-local-map
                        (make-composed-keymap
                         elfai--multi-source-minibuffer-map
                         (current-local-map))))
                   (let ((source (nth idx sources)))
                     (setq curr (apply (car source)
                                       (cdr source))))))))
          (when (numberp source-idx)
            (setq idx (+ idx source-idx))
            (setq idx (if (< idx 0)
                          (1- (length sources))
                        (if (>= idx (length sources))
                            0
                          idx))))))
    curr))

(defun elfai--multi-source-select-prev ()
  "Select the previous item in a multi-source list."
  (interactive)
  (throw 'next -1))

(defun elfai--source-select-next ()
  "Move to the next source selection."
  (interactive)
  (throw 'next 1))

(defun elfai--read-file-name (prompt &optional dir default-filename mustmatch
                                     initial predicate)
  "PROMPT user to select a file, with preview and custom actions.

Argument PROMPT is a string displayed as the prompt in the minibuffer.

Optional argument DIR is the directory to use for completion; it defaults to the
current directory.

Optional argument DEFAULT-FILENAME is the default file name offered for
completion.

Optional argument MUSTMATCH, if non-nil, means the user is not allowed to exit
unless the input matches one of the available file names.

Optional argument INITIAL specifies the initial input to the minibuffer.

Optional argument PREDICATE, if non-nil, is a function that takes one argument
\(a file name) and returns non-nil if that file name should be considered."
  (let* ((prev-file-buffs)
         (preview-action (lambda (file)
                           (when (and file
                                      (file-exists-p file)
                                      (file-readable-p file)
                                      (not (file-directory-p file))
                                      (not
                                       (and large-file-warning-threshold
                                            (let ((size
                                                   (file-attribute-size
                                                    (file-attributes
                                                     (file-truename file)))))
                                              (and size
                                                   (> size
                                                      large-file-warning-threshold)
                                                   (message
                                                    "File is too large (%s) for preview "
                                                    size))))))
                             (if-let ((buff (get-file-buffer
                                             file)))
                                 (unless (get-buffer-window
                                          buff)
                                   (with-selected-window
                                       (let ((wind
                                              (selected-window)))
                                         (or
                                          (window-right
                                           wind)
                                          (window-left
                                           wind)
                                          (split-window-sensibly)
                                          wind))
                                     (pop-to-buffer-same-window buff)))
                               (with-selected-window
                                   (let ((wind
                                          (selected-window)))
                                     (or
                                      (window-right
                                       wind)
                                      (window-left
                                       wind)
                                      (split-window-sensibly)
                                      wind))
                                 (find-file file))
                               (push (get-file-buffer
                                      file)
                                     prev-file-buffs))))))
    (minibuffer-with-setup-hook
        (lambda ()
          (when (minibufferp)
            (let ((map (make-sparse-keymap)))
              (define-key map (kbd "C->")
                          (lambda ()
                            (interactive)
                            (throw 'next 1)))
              (use-local-map (make-composed-keymap map
                                                   (current-local-map))))
            (when preview-action
              (add-hook 'after-change-functions (lambda (&rest _)
                                                  (elfai--minibuffer-action-no-exit
                                                   preview-action))
                        nil t))))
      (read-file-name prompt
                      dir
                      default-filename mustmatch initial predicate))))


(defun elfai-fetch-models (&optional on-success)
  "Fetch GPT models from OpenAI API and run ON-SUCCESS with them.

Optional argument ON-SUCCESS is a function to call with the models list."
  (let ((url-request-method "GET")
        (url "https://api.openai.com/v1/models")
        (url-request-extra-headers
         `(("Content-Type" . "application/json")
           ("Authorization" . ,(format "Bearer %s"
                                (elfai-get-api-key))))))
    (url-retrieve url
                  (lambda (status)
                    (if-let ((err (elfai--retrieve-error
                                   status)))
                        (minibuffer-message "Error while fetching models: %s"
                                            err)
                      (goto-char url-http-end-of-headers)
                      (let* ((json-object-type 'alist)
                             (json-array-type 'list)
                             (response (elfai--json-read-buffer))
                             (models (cdr (assq 'data response))))
                        (when on-success
                          (funcall on-success models)))))
                  nil
                  t t)))

(defun elfai--get-minibuffer-text-parts ()
  "Split minibuffer text into two parts: before and after the cursor."
  (cons (buffer-substring-no-properties
         (minibuffer-prompt-end)
         (point))
        (buffer-substring-no-properties
         (point)
         (line-end-position))))

(defun elfai--normalize-models (models)
  "Convert each model in MODELS to a cons cell with its ID as the car.

Argument MODELS is a list of alists, each representing a model."
  (mapcar (lambda (it)
            (cons (alist-get 'id it) it))
          models))

(defun elfai--sort-models-by-time (items)
  "Sort ITEMS by creation time in descending order.

Argument ITEMS is either a list of cars from `elfai-models-sorted' or
an alist of GPT model names and model response data."
  (reverse
   (seq-sort-by
    (lambda (item)
      (let ((data
             (cdr (if (consp item)
                      item
                    (assoc item elfai-models-sorted)))))
        (seconds-to-time (alist-get 'created data))))
    #'time-less-p items)))

(defun elfai--completing-read-model (prompt &optional predicate require-match
                                            initial-input hist &rest args)
  "Choose a GPT model with annotations and sorting by creation time.

Argument PROMPT is a string displayed as the prompt in the minibuffer.

Optional argument PREDICATE is a function to filter choices; only those for
which it returns non-nil are displayed.

Optional argument REQUIRE-MATCH determines if input must exactly match one of
the completion candidates. It defaults to nil.

Optional argument INITIAL-INPUT is a string to prefill the minibuffer with.

Optional argument HIST specifies the history list to use for saving the input.
It defaults to `minibuffer-history'.

Remaining arguments ARGS are additional arguments passed to `completing-read'."
  (let* ((align)
         (annotf (lambda (str)
                   (when (and (not align)
                              elfai-models-sorted)
                     (setq align
                           (1+
                            (apply #'max (mapcar
                                          (lambda (it) (length (car it)))
                                          elfai-models-sorted)))))
                   (when-let ((created
                               (alist-get
                                'created
                                (cdr (assoc str elfai-models-sorted)))))
                     (concat
                      (propertize " " 'display `(space :align-to ,(or align 40)))
                      (or (elfai--format-time-diff created) " ")))))
         (display-sort-fn #'elfai--sort-models-by-time)
         (collection (lambda (str pred action)
                       (if (eq action 'metadata)
                           `(metadata
                             (annotation-function . ,annotf)
                             (display-sort-function .
                              ,display-sort-fn))
                         (complete-with-action action
                                               elfai-models-sorted
                                               str
                                               pred))))
         (text-parts)
         (result
          (catch 'fetched
            (minibuffer-with-setup-hook
                (lambda ()
                  (when (minibufferp)
                    (if (not elfai-models-sorted)
                        (elfai-fetch-models
                         (lambda (models)
                           (setq elfai-models-sorted
                                 (elfai--sort-models-by-time
                                  (elfai--normalize-models models)))
                           (when-let ((wnd (active-minibuffer-window)))
                             (with-selected-window wnd
                               (setq text-parts
                                     (elfai--get-minibuffer-text-parts))
                               (throw 'fetched t)))))
                      (setq text-parts
                            (elfai--get-minibuffer-text-parts))
                      (throw 'fetched t))))
              (apply #'completing-read
                     prompt
                     collection
                     predicate require-match initial-input
                     hist args)))))
    (if (eq result t)
        (minibuffer-with-setup-hook
            (lambda ()
              (when (minibufferp)
                (pcase-let ((`(,left-text . ,right-text) text-parts))
                  (when left-text
                    (insert left-text))
                  (when right-text
                    (save-excursion
                      (insert right-text))))))
          (apply #'completing-read
                 prompt
                 collection
                 predicate require-match nil
                 hist args))
      result)))

(defun elfai--read-gpt-model-variable (prompt &optional predicate
                                                require-match initial-input hist
                                                &rest args)
  "Read a GPT model variable with completion, showing its value as annotation.

Argument PROMPT is a string to display as the prompt.

Optional argument PREDICATE is a function to filter the choices.

Optional argument REQUIRE-MATCH determines if input must match one of the
choices.

Optional argument INITIAL-INPUT is the initial input in the minibuffer.

Optional argument HIST specifies the history list to use.

Remaining arguments ARGS are additional arguments passed to `completing-read'."
  (let* ((annotf (lambda (str)
                   (when-let ((sym (intern-soft str)))
                     (and (custom-variable-p sym)
                          (let ((val (symbol-value sym)))
                            (concat " " (or val "")))))))
         (items
          (let ((data)
                (first-items))
            (mapatoms (lambda (sym)
                        (ignore-errors
                          (when (or (custom-variable-p sym)
                                    (boundp sym))
                            (let ((val (symbol-value sym)))
                              (if
                                  (and (stringp val)
                                       (if elfai-models-sorted
                                           (assoc-string
                                            val
                                            elfai-models-sorted)
                                         (string-prefix-p "gpt-" val)))
                                  (push sym
                                        first-items)
                                (when (or (not val)
                                          (and (stringp val)
                                               (or (string-empty-p
                                                    val))))
                                  (push sym data))))))))
            (append first-items data)))
         (collection (lambda (str pred action)
                       (if (eq action 'metadata)
                           `(metadata
                             (annotation-function . ,annotf))
                         (complete-with-action action
                                               items
                                               str
                                               pred)))))
    (apply #'completing-read
           prompt
           collection
           predicate require-match initial-input
           hist args)))


(defun elfai-set-or-save-variable (var-sym value &optional comment)
  "Ask to save VAR-SYM with VALUE, set it directly, or show a message.

Argument VAR-SYM is the symbol of the variable to set or save.

Argument VALUE is the new value to assign to VAR-SYM.

Optional argument COMMENT is a string to display as a message after setting or
saving."
  (if (and (not noninteractive)
           (yes-or-no-p (format "Save %s with value %s?" var-sym value)))
      (customize-save-variable var-sym value
                               "Saved by elfai-set-or-save-variable")
    (funcall (or
              (get var-sym 'custom-set)
              #'set-default)
             var-sym
             value)
    (message (or comment (format "Variable's %s value is setted to %s"
                                 var-sym value))))
  value)

;;;###autoload
(defun elfai-set-model (variable model)
  "Set the value of VARIABLE to MODEL, optionally saving it.

Argument VARIABLE is the name of the variable to set.

Argument MODEL is the new value to assign to the variable."
  (interactive (list
                (elfai--read-gpt-model-variable "Variable: ")
                (elfai--completing-read-model "Model: ")))
  (elfai-set-or-save-variable (intern-soft variable) model))

;;;###autoload
(defun elfai-change-default-model (model)
  "Set `elfai-gpt-model' to MODEL.

Argument MODEL is the name of the GPT model to set."
  (interactive (list
                (elfai--completing-read-model "Model: ")))
  (elfai-set-model 'elfai-gpt-model model))


(defun elfai-get-region ()
  "Return current active region as string or nil."
  (when (and (region-active-p)
             (use-region-p))
    (buffer-substring-no-properties
     (region-beginning)
     (region-end))))

(defun elfai--normalize-assistent-prompt (content)
  "Trim and remove specific prefixes and suffixes from CONTENT.

Argument CONTENT is the text to be normalized."
  (let ((prefix (and elfai-response-prefix
                     (string-trim elfai-response-prefix)))
        (suffix (and elfai-response-suffix
                     (string-trim elfai-response-suffix))))
    (setq content (string-trim content))
    (when (and prefix (string-prefix-p prefix content))
      (setq content (substring-no-properties content (length prefix))))
    (when (and suffix (string-suffix-p suffix content))
      (setq content (substring-no-properties content 0
                                             (- (length content)
                                                (length suffix)))))
    content))

(defun elfai--debug (result)
  "Display debug information in a buffer if `elfai-debug' is enabled.

Argument RESULT is the value to be debugged; it can be a string or any Lisp
object."
  (when elfai-debug
    (with-current-buffer (get-buffer-create "*Elfai-debug*")
      (visual-line-mode 1)
      (goto-char (point-max))
      (insert "\n")
      (insert (if (stringp result)
                  result
                (pp-to-string result))))))

(defun elfai--parse-buffer ()
  "Parse buffer for text properties, categorizing content as user or assistant."
  (let ((prompts)
        (prop)
        (result))
    (while (and
            (setq prop (text-property-search-backward
                        'elfai 'response
                        (when (get-char-property (max (point-min) (1- (point)))
                                                 'elfai)
                          t))))
      (let ((role (if (prop-match-value prop) "assistant" "user")))
        (push
         (list
          :role role
          :content
          (let ((content (buffer-substring-no-properties
                          (prop-match-beginning
                           prop)
                          (prop-match-end
                           prop))))
            (string-trim
             (pcase role
               ("assistant"
                (elfai--normalize-assistent-prompt content))
               (_ (replace-regexp-in-string
                   (concat "^" (regexp-quote
                                elfai-user-prompt-prefix))
                   ""
                   (string-trim content)))))))
         prompts)))
    (setq result (cons (list
                        :role "system"
                        :content (or (elfai-system-prompt)
                                     ""))
                       prompts))
    (elfai--debug result)
    result))

(defun elfai--line-empty-p ()
  "Check if the current line is empty, ignoring whitespace."
  (string-empty-p
   (string-trim (buffer-substring-no-properties
                 (line-beginning-position)
                 (line-end-position)))))

(defun elfai-count-empty-lines (&optional direction)
  "Count the number of consecutive empty lines from a point.

The optional argument DIRECTION specifies the direction to count empty lines. It
defaults to 1."
  (let ((count 0))
    (save-excursion
      (while (and (not (bobp))
                  (progn (forward-line (or direction 1))
                         (elfai--line-empty-p)))
        (setq count (1+ count))))
    count))

(defun elfai--ensure-newlines ()
  "Ensure correct number of newlines around the current line."
  (unless (elfai--line-empty-p)
    (end-of-line)
    (insert "\n"))
  (let ((count (- 0
                  (elfai-count-empty-lines -1))))
    (if (> count 0)
        (newline count)
      (if (< count 0)
          (dotimes (_i (- count))
            (join-line))))))

(defun elfai--presend ()
  "Insert response prefix, suffix, and add text properties between points."
  (elfai--ensure-newlines)
  (let ((beg (point))
        (end))
    (insert elfai-response-prefix)
    (save-excursion
      (insert elfai-response-suffix)
      (setq end (point)))
    (add-text-properties
     beg end (append elfai-props-indicator line-prefix))))

(defun elfai-send ()
  "Send parsed buffer messages to an AI model for completion."
  (interactive)
  (let ((req-data
         (cond ((elfai-minor-mode-p 'elfai-image-mode)
                (list
                 :max_tokens 500
                 :messages (apply #'vector
                                  (save-excursion
                                    (elfai--parse-image-buffer)))
                 :model "gpt-4-vision-preview"
                 :temperature elfai-gpt-temperature
                 :stream t))
               (t (list
                   :messages (apply #'vector
                                    (save-excursion
                                      (elfai--parse-buffer)))
                   :model elfai-gpt-model
                   :temperature elfai-gpt-temperature
                   :stream t)))))
    (save-excursion
      (elfai--presend)
      (elfai--update-status " Waiting" 'warning)
      (elfai--stream-request
       req-data
       (lambda ()
         (elfai--update-status " Ready" 'success))
       nil
       nil
       :error-callback (lambda (err)
                         (elfai--update-status (truncate-string-to-width (format
                                                                          " Error: %s"
                                                                          err)
                                                                         50)
                                               'error))))))


;;;###autoload
(define-minor-mode elfai-image-mode
  "Runs elfai on file save when this mode is turned on."
  :lighter " elfai-img"
  :global nil
  :keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c RET") #'elfai-send)
    map)
  (cond (elfai-image-mode
         (setq elfai-old-header-line header-line-format)
         (setq header-line-format (elfai-get-header-line)))
        (t (setq header-line-format elfai-old-header-line)
           (setq elfai-old-header-line nil))))

(defvar org-link-types-re)
(defun elfai--parse-image-data (content)
  "Parse image data from CONTENT, replacing links with encoded images.

Argument CONTENT is the string containing the image data to be parsed."
  (require 'org)
  (let ((data))
    (with-temp-buffer
      (insert content)
      (print content)
      (while (re-search-backward "\\[\\[\\([^]]+\\)\\]\\]" nil t 1)
        (when-let ((image-file (match-string-no-properties 1)))
          (replace-match "" nil nil nil 0)
          (let ((file (if org-link-types-re
                          (replace-regexp-in-string org-link-types-re
                                                    "" image-file)
                        image-file)))
            (when (file-exists-p file)
              (let ((props `(:type
                             "image_url"
                             :image_url
                             (:url ,(elfai--encode-image
                                     (replace-regexp-in-string org-link-types-re
                                      "" image-file))))))
                (push props data))))))
      (push `(:type
              "text"
              :text
              ,(replace-regexp-in-string
                (concat "^"
                 (regexp-quote elfai-user-prompt-prefix))
                ""
                (string-trim (buffer-string))))
            data))
    (apply #'vector data)))


(defun elfai--parse-image-buffer ()
  "Parse buffer for gpt vision model."
  (let ((prompts)
        (prop))
    (while (and
            (setq prop (text-property-search-backward
                        'elfai 'response
                        (when (get-char-property (max (point-min) (1- (point)))
                                                 'elfai)
                          t))))
      (let ((role (if (prop-match-value prop) "assistant" "user")))
        (push
         (list
          :role role
          :content
          (let ((content (buffer-substring-no-properties
                          (prop-match-beginning
                           prop)
                          (prop-match-end
                           prop))))
            (pcase role
              ("assistant"
               (elfai--normalize-assistent-prompt content))
              (_
               (elfai--parse-image-data content)))))
         prompts)))
    (when elfai-debug
      (with-current-buffer (get-buffer-create "*Elfai-debug*")
        (visual-line-mode 1)
        (goto-char (point-max))
        (insert "\n")
        (insert (pp-to-string prompts))))
    prompts))

;;;###autoload
(defun elfai-recognize-image (image-file prompt)
  "Send an image to GPT-4 for recognition with a user prompt.

Argument IMAGE-FILE is the path to the image file to be recognized.

Argument PROMPT is the text prompt to accompany the image recognition request."
  (interactive
   (list (elfai--read-image-from-multi-sources)
         (read-string "Prompt: "
                      "What’s in this image? ")))
  (display-buffer
   (with-current-buffer (get-buffer-create "*Elfai-image*")
     (unless (derived-mode-p 'org-mode)
       (org-mode))
     (visual-line-mode 1)
     (unless (elfai-minor-mode-p 'elfai-image-mode)
       (elfai-image-mode))
     (setq-local elfai-gpt-model "gpt-4-vision-preview")
     (goto-char (point-min))
     (insert elfai-user-prompt-prefix prompt "\n" (format "[[%s]]" image-file)
             "\n\n")
     (elfai-send)
     (current-buffer))
   '((display-buffer-reuse-window
      display-buffer-pop-up-window)
     (reusable-frames . visible))))

(defun elfai-get-header-line ()
  "Display a header line with model info and interactive buttons."
  (list
   '(:eval (concat (propertize " " 'display '(space :align-to 0))
            (format "%s" elfai-gpt-model)))
   (propertize " Ready" 'face 'success)
   '(:eval
     (let* ((l1 (length elfai-gpt-model))
            (num-exchanges "[Send: buffer]")
            (l2 (length num-exchanges)))
      (concat
       (propertize
        " " 'display
        `(space :align-to ,(max 1 (- (window-width)
                                   (+ 2 l1 l2)))))
       (propertize
        (buttonize num-exchanges
         (lambda (&rest _)
           (elfai-send)))
        'mouse-face 'highlight
        'help-echo
        "Send buffer")
       " "
       (propertize
        (buttonize (concat "[" elfai-gpt-model "]")
         (lambda (&rest _)
           (elfai-menu)))
        'mouse-face 'highlight
        'help-echo "GPT model in use"))))))

(defun elfai--update-status (&optional msg face)
  "Update status MSG in FACE."
  (when (or (symbol-value 'elfai-mode)
            (symbol-value 'elfai-image-mode))
    (when (consp header-line-format)
      (setf (nth 1 header-line-format)
            (propertize msg 'face face)))))


;;;###autoload
(define-minor-mode elfai-mode
  "Send buffer messages to an AI model for completion with a keybinding.

Enable interaction with an AI model by sending parsed buffer messages for
completion.

This mode facilitates the integration of AI-driven completions into your
workflow, leveraging a specified AI model for generating responses based on the
provided input."
  :lighter " elfai"
  :global nil
  :keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c RET") #'elfai-send)
    map)
  (cond (elfai-mode
         (setq elfai-old-header-line header-line-format)
         (setq header-line-format (elfai-get-header-line)))
        (t (setq header-line-format elfai-old-header-line)
           (setq elfai-old-header-line nil))))

;;;###autoload
(defun elfai-region-convervation (&optional text)
  "Start conservation with selected TEXT in a formatted Org buffer.

Optional argument TEXT is the text to be converted."
  (interactive
   (list (elfai-get-region)))
  (let ((lang (elfai-get-org-language)))
    (display-buffer
     (with-current-buffer (get-buffer-create "*Elfai response*")
       (unless (derived-mode-p 'org-mode)
         (org-mode))
       (visual-line-mode 1)
       (unless (symbol-value 'elfai-mode)
         (elfai-mode))
       (setq-local elfai-gpt-model elfai-gpt-model)
       (goto-char (point-min))
       (insert elfai-user-prompt-prefix)
       (save-excursion
         (insert "\n"
                 (if (not text)
                     ""
                   (if lang
                       (concat (concat "#+begin_src " lang "\n" text "\n"
                                       "#+end_src"))
                     (concat "#+begin_example\n" text "\n#+end_example")))
                 "\n\n"))
       (current-buffer))
     '((display-buffer-reuse-window
        display-buffer-pop-up-window)
       (reusable-frames . visible)))))

(defun elfai--get-error-from-overlay (ov)
  "Extract error details from an overlay, supporting Flymake and Flycheck.

Argument OV is an overlay object."
  (when (overlayp ov)
    (let ((diagnostic))
      (cond ((setq diagnostic (overlay-get ov 'flymake-diagnostic))
             (when (and (fboundp 'flymake-diagnostic-text)
                        (fboundp 'flymake-diagnostic-beg)
                        (fboundp 'flymake-diagnostic-end))
               (list
                (flymake-diagnostic-text diagnostic)
                (flymake-diagnostic-beg diagnostic)
                (flymake-diagnostic-end diagnostic))))
            ((setq diagnostic (overlay-get ov 'flycheck-error))
             (when (and (fboundp 'flycheck-error-format-message-and-id)
                        (fboundp 'flycheck-error-line)
                        (fboundp 'flycheck-error-end-line)
                        (fboundp 'flycheck-error-end-column)
                        (fboundp 'flycheck-error-column)
                        (fboundp 'flycheck-error-pos))
               (let ((pos (flycheck-error-pos diagnostic)))
                 (list
                  (flycheck-error-format-message-and-id
                   diagnostic)
                  pos))))))))

;;;###autoload
(defun elfai-discuss-errors-at-point ()
  "Start convservation about errors in buffer."
  (interactive)
  (let ((errors (reverse (delq nil
                               (mapcar #'elfai--get-error-from-overlay
                                       (overlays-in (point-min)
                                                    (point-max))))))
        (content))
    (setq content (catch 'content
                    (atomic-change-group
                      (pcase-dolist (`(,text ,beg) errors)
                        (goto-char beg)
                        (let ((end))
                          (insert text)
                          (setq end (point))
                          (goto-char beg)
                          (comment-region beg end)))
                      (throw 'content (buffer-substring-no-properties (point-min)
                                                                      (point-max))))))
    (let ((elfai-user-prompt-prefix
           (concat elfai-user-prompt-prefix
                   "Fix the errors, described in comments")))
      (elfai-region-convervation
       content))))

;;;###autoload
(defun elfai-discuss-error-at-point ()
  "Start convservation about error at point."
  (interactive)
  (when-let* ((texts (delete-dups
                      (delq nil
                            (mapcar #'elfai--get-error-from-overlay
                                    (append
                                     (overlays-at (point))
                                     (overlays-in (line-beginning-position)
                                                  (line-end-position)))))))
              (text (caar texts)))
    (let ((beg (point))
          (end)
          (placeholder))
      (with-undo-amalgamate
        (insert text)
        (setq end (point))
        (goto-char beg)
        (comment-region beg end)
        (forward-comment 1)
        (setq end (point))
        (setq placeholder (buffer-substring-no-properties beg end))
        (delete-region beg end))
      (let ((elfai-user-prompt-prefix
             (concat elfai-user-prompt-prefix
                     "Fix the errors, described in comments")))
        (elfai-region-convervation
         (elfai--get-content-with-cursor placeholder))))))

(defun elfai--overlay-make (start end &optional buffer front-advance
                                  rear-advance &rest props)
  "Create a new overlay with range BEG to END in BUFFER and return it.
If omitted, BUFFER defaults to the current buffer.
START and END may be integers or markers.

The fifth arg REAR-ADVANCE, if non-nil, makes the marker
for the rear of the overlay advance when text is inserted there
\(which means the text *is* included in the overlay).
PROPS is a plist to put on overlay."
  (let ((overlay (make-overlay start end buffer front-advance
                               rear-advance)))
    (dotimes (idx (length props))
      (when (eq (logand idx 1) 0)
        (let* ((prop-name (nth idx props))
               (val (plist-get props prop-name)))
          (overlay-put overlay prop-name val))))
    overlay))

(defun elfai--remove-overlays ()
  "Remove all `elfai' property overlays from the current buffer."
  (let ((ovs (car (overlay-lists))))
    (dolist (ov ovs)
      (when (overlay-get ov 'elfai)
        (delete-overlay ov)))))

(defvar org-src-lang-modes)
(defun elfai-get-org-language ()
  "Return the Org mode language associated with the current major mode."
  (require 'org)
  (let ((mode (replace-regexp-in-string "-mode$" "" (symbol-name major-mode))))
    (car (seq-find (pcase-lambda (`(,_lang . ,v))
                     (if (stringp v)
                         (string= v mode)
                       (string= (format "%s" v)  mode)))
                   org-src-lang-modes))))


(define-minor-mode elfai-abort-mode
  "Toggle monitoring `keyboard-quit' commands for aborting GPT requests.

Enable `elfai-abort-mode' to monitor and handle `keyboard-quit'
commands for aborting GPT documentation requests.

When active, pressing `\\[keyboard-quit]' multiple times can trigger the
cancellation of ongoing documentation generation processes.

See also custom variable `elfai-abort-on-keyboard-quit-count' for
exact number of `keyboard-quit' presses to abort."
  :lighter " elfai"
  :global nil
  (if elfai-abort-mode
      (add-hook 'pre-command-hook #'elfai-command-watcher nil 'local)
    (remove-hook 'pre-command-hook #'elfai-command-watcher 'local)
    (setq elfai--bus nil)))

(defun elfai-minor-mode-p (&rest modes)
  "Check if any of the given minor MODES is active.

Remaining arguments MODES are symbols representing minor modes."
  (seq-find #'symbol-value modes))

(defun elfai--index-switcher (step current-index switch-list)
  "Increase or decrease CURRENT-INDEX depending on STEP value and SWITCH-LIST."
  (cond ((> step 0)
         (if (>= (+ step current-index)
                 (length switch-list))
             0
           (+ step current-index)))
        ((< step 0)
         (if (or (<= 0 (+ step current-index)))
             (+ step current-index)
           (1- (length switch-list))))))

(defun elfai-system-prompt ()
  "Return the current system prompt from `elfai-system-prompts'."
  (nth elfai-curr-prompt-idx elfai-system-prompts))

(defun elfai-gpt-temperature-description ()
  "Format and return the current GPT model temperature setting."
  (format "Temperature: %s" elfai-gpt-temperature))


;;;###autoload (autoload 'elfai-menu "elfai" nil t)
(transient-define-prefix elfai-menu ()
  "Provide a menu for various AI-powered text and image processing functions."
  :refresh-suffixes t
  [["At point"
    ("a" "Ask and insert"
     elfai-ask-and-insert :inapt-if-non-nil buffer-read-only)
    ("h" "Complete" elfai-complete-here :inapt-if-non-nil buffer-read-only)
    ("." "Complete (send region before point)"
     elfai-complete-with-partial-context
     :inapt-if-non-nil buffer-read-only)
    ("r" "On Region" elfai-region-convervation)]
   ["Images"
    ("i" "Recognize image" elfai-recognize-image)
    ("g" "Generate images" elfai-generate-images-batch)]]
  [[:description (lambda ()
                   (let ((prompt (or (elfai-system-prompt)
                                     "")))
                     (concat "System prompt: "
                             (truncate-string-to-width
                              (with-temp-buffer
                                (insert prompt)
                                (fill-region (point-min)
                                             (point-max))
                                (buffer-string))
                              80
                              nil
                              nil
                              t))))
    ("p" "Previous system prompt"
     (lambda ()
       (interactive)
       (setq elfai-curr-prompt-idx
             (elfai--index-switcher -1
                                    elfai-curr-prompt-idx
                                    elfai-system-prompts)))
     :transient t)
    ("n" "Next system prompt"
     (lambda ()
       (interactive)
       (setq elfai-curr-prompt-idx
             (elfai--index-switcher 1
                                    elfai-curr-prompt-idx
                                    elfai-system-prompts)))
     :transient t)
    ("SPC" "Add system prompt"
     (lambda ()
       (interactive)
       (string-edit
        "New system prompt: "
        ""
        (lambda (edited)
          (add-to-list 'elfai-system-prompts edited)
          (when-let ((idx
                      (seq-position elfai-system-prompts edited)))
            (setq elfai-curr-prompt-idx idx))
          (transient-setup #'elfai-menu))
        :abort-callback (lambda ())))
     :transient nil)
    ("e" "Edit system prompt"
     (lambda ()
       (interactive)
       (string-edit
        "Edit system prompt: "
        (nth elfai-curr-prompt-idx
             elfai-system-prompts)
        (lambda (edited)
          (setf (nth elfai-curr-prompt-idx elfai-system-prompts)
                edited)
          (transient-setup #'elfai-menu))
        :abort-callback (lambda ())))
     :transient nil)
    ("D" "Delete current system prompt"
     (lambda ()
       (interactive)
       (setq elfai-system-prompts
             (remove (nth elfai-curr-prompt-idx elfai-system-prompts)
                     elfai-system-prompts)))
     :transient t)
    ("C-x C-w" "Save prompts"
     (lambda ()
       (interactive)
       (customize-save-variable
        'elfai-system-prompts
        elfai-system-prompts))
     :transient t)
    ("m" elfai-change-default-model
     :description
     (lambda ()
       (if (elfai-minor-mode-p 'elfai-image-mode)
           "gpt-4-vision-preview"
         (format "Model: %s" elfai-gpt-model))))
    ("<up>"
     (lambda ()
       (interactive)
       (setq elfai-gpt-temperature
             (string-to-number
              (format "%.1f"
                      (min
                       (+
                        (string-to-number
                         (format "%.1f"
                                 (float (or
                                         elfai-gpt-temperature
                                         0))))
                        0.1)
                       2.0)))))
     :description elfai-gpt-temperature-description
     :transient t)
    ("<down>" (lambda ()
                (interactive)
                (setq elfai-gpt-temperature
                      (string-to-number
                       (format "%.1f"
                               (max
                                (-
                                 (string-to-number
                                  (format "%.1f"
                                          (float (or
                                                  elfai-gpt-temperature
                                                  0))))
                                 0.1)
                                0.0)))))
     :description elfai-gpt-temperature-description
     :transient t)]])


(provide 'elfai)
;;; elfai.el ends here
