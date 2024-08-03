;;; elfai.el --- An interface to OpenAI's GPT models -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Karim Aziiev <karim.aziiev@gmail.com>

;; Author: Karim Aziiev <karim.aziiev@gmail.com>
;; URL: https://github.com/KarimAziev/elfai
;; Version: 0.1.0
;; Keywords: tools
;; Package-Requires: ((emacs "29.1") (transient "0.7.1"))
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

;; `elfai' is an Emacs package that provides an interface to OpenAI's GPT models.

;; It offers a variety of commands to interact with GPT models, including text
;; completion, image generation, and more. The package is designed to be
;; user-friendly and integrates seamlessly with Emacs.

;; Key Features:

;; - Seamlessly expand file links to their content in the prompt. Ensure that any
;;   file links included in the prompt are automatically expanded to their actual
;;   content. Use the `elfai-before-parse-buffer-hook' to run before parsing the
;;   buffer for AI model completion, with the default function
;;   `elfai-copy-and-replace-user-links' handling the replacement of user links
;;   with new paths after copying files to the `elfai` directory. This allows
;;   editing of original files without affecting the content sent to the model.

;; - Embed images directly within prompts, and ensure that these images are
;;   included in a format acceptable to the model. Preview org-inline-images in
;;   the buffer and convert them to base64 format if they match the extensions
;;   specified in `elfai-image-allowed-file-extensions'.

;; - Expand #+INCLUDE: directives to include file content in the prompt.

;; - Generate images using OpenAI's API.

;; - Abort ongoing requests.

;; - Integrate transient interface for easy command access.


;; Main Commands:
;; - `elfai': Start or switch to a chat session.
;; - `elfai-menu': Open a transient menu for various AI-powered text and image processing functions.
;; - `elfai-complete-here': Replace placeholder text in a buffer with GPT-generated content.
;; - `elfai-ask-and-insert': Prompt for input and send it to GPT for processing.
;; - `elfai-generate-images-batch': Generate a batch of images.
;; - `elfai-abort-all': Cancel all pending GPT document requests.

;;; Code:

(declare-function text-property-search-backward "text-property-search")
(declare-function prop-match-value "text-property-search")
(declare-function json-pretty-print-buffer "json")

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
(declare-function org-indent-refresh-maybe "org-indent")
(declare-function org-link-open-as-file "ol")
(defvar org-link-types-re)

(require 'transient)

(defcustom elfai-abort-on-keyboard-quit-count 5
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

(defcustom elfai-status-indicator '(elfai-update-header)
  "List of functions to update the status indicator.

A list of functions to update the status indicator.

Each function in the list should accept two arguments:
a message (MSG) and a face property (FACE) to style the message.

The default functions are `elfai-update-header' and
`elfai-update-mode-line-process'. Additional custom functions can
be added to this list."
  :group 'elfai
  :type '(set :tag "Update functions"
          (function-item elfai-update-header)
          (function-item elfai-update-mode-line-process)
          (repeat
           :inline t
           :tag "Custom functions" function)))

(defcustom elfai-before-parse-buffer-hook '(elfai-copy-and-replace-user-links
                                            elfai-copy-and-replace-include-directives)
  "A hook that runs before parsing the chat buffer.

This hook allows customization of actions to be performed on the
buffer content before it is parsed and sent to the AI model.

Each function in the hook should accept no arguments and will be
called in the order they are listed."
  :group 'elfai
  :type 'hook)

(defcustom elfai-non-embeddable-file-extensions '("iso" "bin" "exe" "gpg" "elc"
                                                  "eln" "tar" "gz" "doc" "xlsx"
                                                  "docx" "mp4" "mkv"
                                                  "webm" "3gp" "MOV" "f4v"
                                                  "rmvb" "heic" "HEIC" "mov"
                                                  "wvx" "wmx" "wmv" "wm"
                                                  "asx"
                                                  "mk3d" "fxm" "flv" "axv" "viv"
                                                  "yt" "s1q" "smo" "smov" "ssw"
                                                  "sswf" "s14"
                                                  "s11"
                                                  "smpg" "smk" "bk2" "bik" "nim"
                                                  "pyv" "m4u" "mxu" "fvt" "dvb"
                                                  "uvvv" "uvv"
                                                  "uvvs"
                                                  "uvs" "uvvp" "uvp" "uvvu"
                                                  "uvu" "uvvm" "uvm" "uvvh"
                                                  "uvh" "ogv" "m2v" "m1v"
                                                  "m4v"
                                                  "mpg4" "mjp2" "mj2" "m4s"
                                                  "3gpp2" "3g2" "3gpp" "avi"
                                                  "movie" "mpe" "mpeg"
                                                  "mpegv"
                                                  "mpg" "mpv" "qt" "vbs" "pdf"
                                                  "zip" "rar" "7z" "bz2" "xz"
                                                  "tar.gz" "tar.bz2"
                                                  "tar.xz" "tgz" "tbz2" "txz"
                                                  "dll" "so" "dylib" "lib"
                                                  "class" "jar" "war"
                                                  "ear"
                                                  "img" "dmg" "mp3" "wav" "flac"
                                                  "aac" "ogg" "wma" "m4a" "ppt"
                                                  "pptx" "odp"
                                                  "xls"
                                                  "ods" "epub" "mobi" "azw"
                                                  "azw3" "psd" "ai" "indd" "ttf"
                                                  "otf" "woff"
                                                  "woff2"
                                                  "swf" "fla" "apk" "ipa" "deb"
                                                  "rpm" "pkg" "msi" "bat" "cmd"
                                                  "vmdk" "vdi"
                                                  "vhd" "qcow2" "crt" "pem"
                                                  "key" "csr" "pfx" "p12" "tmp"
                                                  "sqlite" "db" "mdb"
                                                  "accdb" "blend" "fbx" "obj"
                                                  "stl" "dwg" "dxf" "gpx" "kml"
                                                  "torrent" "ics"
                                                  "msg"
                                                  "eml" "vcf" "com" "scr" "pif"
                                                  "cpl" "msc" "drv" "vbox"
                                                  "vbox-extpack"
                                                  "vbox-prev"
                                                  "old" "sav" "tmp" "crdownload"
                                                  "part" "svg" "xpm")
  "List of file extensions that are considered non-embeddable.

This variable defines a list of file extensions that should not be embedded.

These file types include binary files, archives, executables, multimedia files,
and other formats that do not contain standard text or are not suitable for
embedding. Images are excluded from this list as they are allowed to be
embedded.

Examples of non-embeddable file types include:
- Archives (e.g., zip, rar, tar.gz)
- Executables (e.g., exe, bin, dll)
- Multimedia files (e.g., mp4, mkv, mp3)
- Documents (e.g., pdf, docx, xlsx)
- Encrypted files (e.g., gpg, pfx)
- System files (e.g., msi)

This list can be customized to include or exclude specific file extensions
based on your requirements."
  :group 'elfai
  :type '(repeat string))

(defcustom elfai-image-allowed-file-extensions '("png" "jpg" "jpeg" "gif")
  "List of allowed file extensions for image files.

A list of allowed file extensions for image files.

Each element in the list should be a string representing a file
extension, such as \"png\", \"jpg\", or \"jpeg\".

This list is used to filter image files when prompting the user
to select an image file."
  :group 'elfai
  :type '(repeat (string :tag "File extension")))

(defcustom elfai-attachment-dir "~/elfai-attachments/"
  "Directory where elfai attachments are stored."
  :group 'elfai
  :type 'directory)

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
  "Whether to allow debug logging.

Debug messages are logged to the \"*elfai-debug*\" buffer.

If t, all messages will be logged.
If a number, all messages will be logged, as well shown via `message'.
If a list, it is a list of the types of messages to be logged."
  :group 'elfai-debug
  :type '(radio
          (const :tag "none" nil)
          (const
           :tag "all"
           :value t)
          (checklist :tag "custom"
           (integer
            :tag "Allow echo message buffer"
            :value 1)
           (const :tag "Parse" parse-buffer)
           (const :tag "Process" process)
           (const :tag "Response" response)
           (symbol :tag "Other"))))

(defvar-local elfai-loading nil)

(defcustom elfai-api-key 'elfai-api-key-from-auth-source
  "An OpenAI API key (string).

Can also be a function of no arguments that returns an API
key (more secure)."
  :group 'elfai
  :type '(radio
          (string :tag "API key")
          (function-item elfai-api-key-from-auth-source)
          (function :tag "Function that returns the API key")))

(defcustom elfai-allowed-include-directives '((copy
                                               "#+include_copy:")
                                              (identity "#+include:"))
  "Alist of allowed include directives for buffer processing.

An alist defining allowed include directives and their handling
methods.

Each key is a method, either `copy' or `identity'. The value is a
list of strings representing the include directives associated
with that method.

- `copy': Directives that should be copied verbatim.

- `identity': Directives that should be processed as-is."
  :group 'elfai
  :type '(alist
          :key-type (radio :tag "Method"
                     (const copy)
                     (const identity))
          :value-type (repeat :tag "Directive" string)))

(defcustom elfai-gpt-url "https://api.openai.com/v1/chat/completions"
  "The URL to the OpenAI GPT API endpoint for chat completions."
  :group 'elfai
  :type 'string)


(defcustom elfai-model "gpt-4o"
  "A string variable representing the API model for OpenAI."
  :group 'elfai
  :type 'string)


(defcustom elfai-temperature 1.0
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

(defcustom elfai-response-prefix "\n\n#+begin_src markdown\n"
  "The prefix to be inserted before responses in the assistant's output.

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

(defcustom elfai-response-suffix "\n#+end_src\n\n"
  "Custom string to insert at the end of LLM responses.

The default value is a newline followed by the end of the Org mode source
block declaration.

See also `elfai-response-prefix'."
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

(defcustom elfai-system-prompt-alist '(("None" . "")
                                       ("Org" . "Please respond using Org-mode syntax. For example, use =symbol-name= instead of `symbol-name`. For lists, use \"-\" or bullets instead of numerical or alphabetical lists.")
                                       ("Grammar" . "Check grammar")
                                       ("Refactor" . "Rewrite this function"))
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
  :type '(alist
          :key-type string
          :value-type string)
  :group 'elfai)

(defconst elfai-props-indicator '(elfai response rear-nonsticky t))

(defcustom elfai-stream-after-insert-hook nil
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

(defcustom elfai-after-full-response-insert-hook nil
  "Hook run after inserting the full response.

A hook that runs after a full response has been inserted.

This hook is useful for performing additional actions or
processing after the insertion of a complete response. Each
function in the hook is called with two arguments: the beginning
and end positions of the inserted text."
  :group 'elfai
  :type 'hook)

(defcustom elfai-after-full-response-insert-functions nil
  "Abnormal hook to run after inserting a full response.

Each function in the list is called with two arguments: the
beginning and end positions of the inserted text.

This allows for additional processing or actions to be performed on the
inserted text, such as syntax highlighting, formatting, or
further analysis."
  :group 'elfai
  :type 'hook)


(defmacro elfai--json-encode (object)
  "Return JSON-encoded representation of OBJECT.

Argument OBJECT is the Lisp object to be encoded into JSON format."
  (if (fboundp 'json-serialize)
      `(json-serialize ,object
        :null-object nil
        :false-object :json-false)
    (require 'json)
    (defvar json-false)
    (declare-function json-encode "json" (object))
    `(let ((json-false :json-false))
      (json-encode ,object))))

(defvar-local elfai--bounds nil)
(put 'elfai--bounds 'safe-local-variable #'always)

(declare-function org-link-make-regexps "ol")

(defvar-local elfai-old-header-line nil)
(defvar-local elfai-curr-prompt-idx 0)

(defvar elfai--request-url-buffers nil
  "Alist of active request buffers requests.")

(defvar elfai--debug-data-raw nil
  "Stores raw data for debugging purposes.")

(defvar auth-sources)

(defvar elfai--multi-source-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C->") #'elfai--source-select-next)
    (define-key map (kbd "C-j") #'elfai--preview-minibuffer-file)
    (define-key map (kbd "C-<") #'elfai--multi-source-select-prev)
    map)
  "Keymap to use in minibuffer.")

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

(defun elfai-abort-all ()
  "Terminate the process associated with a buffer BUFF and delete its buffer.

Argument BUFF is the buffer in which the process to be aborted is running."
  (interactive)
  (elfai--abort-all))

(defun elfai--debug (tag &rest args)
  "Log debug messages based on the variable `elfai-debug'.

Argument TAG is a symbol or string used to identify the debug message.

Remaining arguments ARGS are format string followed by objects to format,
similar to `format' function arguments."
  (when (and elfai-debug
             (or (eq elfai-debug t)
                 (numberp elfai-debug)
                 (and (listp elfai-debug)
                      (memq tag elfai-debug))))
    (with-current-buffer (get-buffer-create "*elfai-debug*")
      (goto-char (point-max))
      (insert (format "%s" tag) " -> " (apply #'format args) "\n")
      (when (numberp elfai-debug)
        (apply #'message args)))))

(defun elfai--read-custom-choices (prompt ctype-list)
  "Read a custom choice from a list of types and return the selected value.

Argument PROMPT is a string used to prompt the user.

Argument CTYPE-LIST is a list of custom types and their properties."
  (let ((stack ctype-list)
        (const-choices)
        (readers))
    (while stack
      (pcase-let* ((`(,type . ,plist)
                    (car stack))
                   (value)
                   (tag)
                   (item-prompt)
                   (default-value))
        (setq stack (cdr stack))
        (while (keywordp (car plist))
          (let ((keyword (car plist))
                (val (cadr plist)))
            (setq plist (cddr plist))
            (pcase keyword
              (:value (setq value val))
              (:tag (setq tag val))
              (_))))
        (when type
          (setq item-prompt (if tag
                                (format "%s (%s): " tag type)
                              (format "%s: " type)))
          (setq default-value (or value
                                  (car plist))))
        (pcase type
          ((pred not)
           nil)
          ((or 'choice 'radio 'set 'checklist)
           (when (and plist (and (car plist)
                                 (proper-list-p (car plist))))
             (setq stack (append stack plist))))
          ((or 'const
               'function-item
               'variable-item)
           (push (cons (format "%s (`%s'): "
                               item-prompt
                               default-value)
                       default-value)
                 const-choices))
          (_
           (let* ((label item-prompt)
                  (reader
                   (pcase type
                     ('string (apply-partially #'read-string label
                                               default-value))
                     ((or 'integer
                          'number
                          'float
                          'natnum)
                      (apply-partially #'read-number
                                       label
                                       default-value))
                     ('regexp (apply-partially #'read-regexp label
                                               default-value))
                     ((or 'other 'sexp 'list 'vector))
                     ('symbol (lambda ()
                                (intern
                                 (read-string
                                  label
                                  (when default-value
                                    (format "%s" default-value)))))))))
             (push (cons label reader) readers))))))
    (let* ((choice (completing-read prompt
                                    (append (mapcar #'car
                                                    (reverse const-choices))
                                            (mapcar #'car (reverse readers))))))
      (if (assoc choice const-choices)
          (cdr (assoc choice const-choices))
        (if (assoc choice readers)
            (when (functionp (cdr (assoc choice readers)))
              (funcall (or (cdr (assoc choice readers))))))))))

(defun elfai-toggle-debug ()
  "Toggle the value of the `elfai-debug' variable based on user input."
  (interactive)
  (let ((value (elfai--read-custom-choices
                (format "Change `%s' value (%s): "
                        'elfai-debug
                        (symbol-value
                         'elfai-debug))
                (get 'elfai-debug 'custom-type))))
    (elfai-set-or-save-variable 'elfai-debug value)))

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
          (setq end (point-max))))
      (cons beg end))))

(defun elfai--remove-text-props (boundary-prop &optional props)
  "Remove specified text properties within the boundaries of a given property.

Argument BOUNDARY-PROP is the text property used to determine the boundaries.

Optional argument PROPS is a list of text properties to be removed."
  (pcase-let ((`(,beg . ,end)
               (elfai--property-boundaries boundary-prop)))
    (when (and beg end)
      (remove-text-properties beg end props))))

(defun elfai-abort-current-buffer ()
  "Cancel processing in the active buffer."
  (let ((buff (current-buffer)))
    (elfai-abort-buffer buff)))

(defun elfai--abort-by-url-buffer (url-buff)
  "Cancel ongoing URL fetch and close buffer.

Argument URL-BUFF is the buffer associated with the URL retrieval process to be
aborted."
  (pcase-dolist (`(,req-buff . ,marker) elfai--request-url-buffers)
    (elfai--debug 'process
                  "request buffer check `%s'" req-buff)
    (when (or (eq url-buff t)
              (eq req-buff url-buff))
      (when (buffer-live-p req-buff)
        (let ((proc (get-buffer-process req-buff)))
          (elfai--debug 'process
                        "process `%S' status `%s'\nlive: `%s'\n process-plist `%S'"
                        proc (process-status proc)
                        (process-live-p proc)
                        (process-plist proc))
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
       (`(_err ,type ,code . _rest) status-error)
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
                             (when type  (format "%s" type))
                             (when code (format "because of %s" code))
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


(defun elfai--stream-insert-response (response info)
  "Insert and format RESPONSE text at a marker.

Argument RESPONSE is a string containing the server's response.

Argument INFO is a property list containing the insertion position and tracking
information."
  (let ((start-marker (plist-get info :position))
        (tracking-marker (plist-get info :tracking-marker))
        (inserter (plist-get info :inserter))
        (text-props (or (plist-get info :text-props-indicator)
                        elfai-props-indicator)))
    (when response
      (with-current-buffer (marker-buffer start-marker)
        (save-excursion
          (unless tracking-marker
            (goto-char start-marker)
            (setq tracking-marker (set-marker (make-marker) (point)))
            (set-marker-insertion-type tracking-marker t)
            (plist-put info :tracking-marker tracking-marker))
          (goto-char tracking-marker)
          (add-text-properties 0 (length response) text-props response)
          (funcall (or inserter #'insert) response)
          (run-hooks 'elfai-stream-after-insert-hook))))))


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
                                      (elfai--remove-text-props 'elfai
                                                                elfai-props-indicator)))
                                  (setq elfai--request-url-buffers
                                        (assq-delete-all
                                         (plist-get info :request-buffer)
                                         elfai--request-url-buffers))
                                  (when (symbol-value 'elfai-abort-mode)
                                    (elfai-abort-mode -1))
                                  (run-hook-with-args
                                   'elfai-after-full-response-insert-functions
                                   beg
                                   end)
                                  (run-hooks
                                   'elfai-after-full-response-insert-hook)))))
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
                            (elfai--json-encode
                             request-data)
                            'utf-8))
         (request-buffer)
         (typing)
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
                                          :position))
                              (elfai-props-indicator (or
                                                      (plist-get info
                                                                 :text-props-indicator)
                                                      elfai-props-indicator)))
                          (elfai--abort-by-marker start-marker)))))
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (unless (or (plist-get info :inhibit-status) typing)
                      (setq typing t)
                      (elfai--update-status " Typing..." 'warning t))
                    (elfai--stream-insert-response
                     (elfai--get-response-content
                      response)
                     info))))))))
    (plist-put info :callback callback)
    (setq request-buffer
          (condition-case err
              (url-retrieve elfai-gpt-url
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
                                           (plist-get info :position))
                                          (elfai-props-indicator (or (plist-get info :text-props-indicator)
                                                                     elfai-props-indicator)))
                                      (message "elfai-props-indicator 2=`%S'" elfai-props-indicator)
                                      (elfai--abort-by-marker start-marker)))))))
            (error (message "elfai: url-retrieve error `%s'" err))))
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
                                :model elfai-model
                                :temperature
                                elfai-temperature
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
         (let ((count
                (- elfai-abort-on-keyboard-quit-count
                   (length elfai--bus))))
           (cond ((zerop count)
                  (setq elfai--bus nil)
                  (elfai-abort-all)
                  (elfai--update-status " Aborted" 'warning)
                  (message (propertize "Aborted" 'face 'warning)))
                 ((<= count 2)
                  (let ((msg
                         (substitute-command-keys
                          (format
                           " Press `\\[keyboard-quit]' %d more times to abort"
                           count))))
                    (elfai--update-status msg 'warning t)
                    (message msg))))))
        (elfai--bus (setq elfai--bus nil))))

;;;###autoload
(define-minor-mode elfai-mode
  "Enable AI-assisted text generation and image handling in Org-mode buffers.

Enable enhanced language model interactions by providing key bindings and hooks
for sending buffer content to an AI model.

Activate Org mode if not already active, and set up Org link parameters for
image handling. Customize the header line to display model information and
interactive buttons. Manage state restoration and saving through hooks, and
handle AI model requests with customizable parameters."
  :lighter " elfai"
  :global nil
  :keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c RET") #'elfai-send)
    map)
  (cond (elfai-mode
         (add-hook 'org-font-lock-hook #'elfai--restore-state nil t)
         (unless (derived-mode-p 'org-mode)
           (org-mode))
         (when (and (fboundp 'org-link-set-parameters)
                    (fboundp 'org-link-complete-file))
           (org-link-set-parameters
            "elfai-image"
            :complete #'elfai--read-image-from-multi-sources
            :follow #'org-link-open-as-file)
           (org-link-set-parameters
            "elfai-img-relative"
            :complete (lambda (&rest _)
                        (elfai--read-image-from-multi-sources '(16)))
            :follow #'org-link-open-as-file))
         (add-hook 'before-save-hook #'elfai--save-state nil t)
         (setq elfai-old-header-line header-line-format)
         (setq header-line-format (elfai-get-header-line)))
        (t
         (remove-hook 'before-save-hook #'elfai--save-state t)
         (setq header-line-format elfai-old-header-line)
         (setq elfai-old-header-line nil))))

(put 'elfai-mode 'permanent-local t)

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
    (elfai--debug 'complete "`%s" gpt-content)
    (elfai-stream prompt gpt-content nil nil nil
                  :inhibit-status t
                  :text-props-indicator '(elfai-completion response
                                          rear-nonsticky t))))

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
download fails. It defaults to `message'.

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
                          (funcall (or on-error #'message) err)
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
                              (elfai--json-encode
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
      (message err)
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

Optional argument COUNT is the number of images to generate; it defaults to 10."
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

(defun elfai--open-file-extern (file)
  "Open FILE with the default external application based on the system type.

Argument FILE is the path to the file to be opened."
  (if (and (eq system-type 'windows-nt)
           (fboundp 'w32-shell-execute))
      (w32-shell-execute "open" file)
    (call-process-shell-command (format "%s %s"
                                        (pcase system-type
                                          ('darwin "open")
                                          ('cygwin "cygstart")
                                          (_ "xdg-open"))
                                        (shell-quote-argument (expand-file-name
                                                               file)))
                                nil 0)))

(defun elfai--notify-about-file (file &rest params)
  "Send a notification about a recorded screencast with an option to open it.

Argument FILE is the path to the screencast file.

Remaining arguments PARAMS are additional parameters passed to
`notifications-notify'."
  (require 'notifications)
  (when (fboundp 'notifications-notify)
    (apply #'notifications-notify
           :title (format "Image %s ready" (file-name-nondirectory file))
           :body (format "Click here to open %s" file)
           :actions `("default" ,(format "Click here to open %s" file))
           :urgency 'critical
           :on-action (lambda (_id key)
                        (pcase key
                          ("default"
                           (message "openning")
                           (find-file-other-window file))))
           params)))

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
    elfai--vertico-selected
    elfai--get-minibuffer-get-default-completion))

(declare-function vertico--candidate "ext:vertico")
(declare-function vertico--update "ext:vertico")

(defun elfai--vertico-selected ()
  "Target the currently selected item in Vertico.
Return the category metadatum as the type of the target."
  (when (bound-and-true-p vertico--input)
    (vertico--update)
    (cons (completion-metadata-get (elfai--minibuffer-get-metadata) 'category)
          (vertico--candidate))))

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
  (seq-sort-by
   (pcase-lambda (`(,_k . ,v)) v)
   (lambda (a b)
     (not (time-less-p a b)))
   (mapcar
    (lambda (file)
      (cons
       (abbreviate-file-name file)
       (file-attribute-modification-time
        (file-attributes
         file))))
    files)))



(defun elfai--map-to-arguments (arg arg-values &optional format-str)
  "Return a list of ARG paired with each formatted/unformatted value in ARG-VALUES.

Argument ARG is the argument name to be mapped.

Argument ARG-VALUES is a list of values to be mapped to ARG.

Optional argument FORMAT-STR is a format string to format each value in
ARG-VALUES."
  (mapcan (lambda (it)
            (list arg (if format-str
                          (format format-str
                                  it)
                        it)))
          arg-values))


(defun elfai--fdfind-completing-read (&optional prompt)
  "Search files asynchronously with completion and preview.

Argument PROMPT is a string displayed as the prompt in the minibuffer."
  (let ((default-directory (expand-file-name "~/")))
    (let* ((output-buffer "*async-completing-read*")
           (fdfind-program  (or (executable-find "fd")
                                (executable-find "fdfind")))
           (args (if fdfind-program
                     (append
                      (list "-0" "--color=never")
                      (elfai--map-to-arguments
                       "-e"
                       elfai-image-allowed-file-extensions)
                      (elfai--map-to-arguments "-E"
                                               '("chromium" "chrome"
                                                 "node_modules")))
                   (list "-type" "f" "-name"
                         "'*.png'")))
           (async-time)
           (alist)
           (annotf
            (lambda (file)
              (concat (propertize " " 'display (list 'space :align-to 120))
                      (elfai--format-time-diff (cdr (assoc-string file
                                                                  alist))))))
           (proc)
           (update-fn
            (lambda ()
              (let ((mini (active-minibuffer-window))
                    (buff (get-buffer output-buffer)))
                (when (buffer-live-p buff)
                  (with-current-buffer (get-buffer output-buffer)
                    (let ((new-lines (mapcar
                                      (lambda (line)
                                        (expand-file-name
                                         line
                                         default-directory))
                                      (split-string
                                       (buffer-string)
                                       "\0"
                                       t))))
                      (setq alist (nconc alist
                                         (elfai--files-to-sorted-alist
                                          new-lines)))))
                  (when mini
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
                        (_
                         (completion--flush-all-sorted-completions)))))))))
           (time-to-wait 500000))
      (unwind-protect
          (progn
            (setq proc
                  (apply
                   #'start-process "*async-completing-read*" output-buffer
                   (or
                    fdfind-program
                    (executable-find "find"))
                   args))
            (setq async-time (current-time))
            (set-process-sentinel proc
                                  (lambda
                                    (process _state)
                                    (let ((proc-status (process-status process))
                                          (buff (process-buffer process)))
                                      (when (memq proc-status '(exit signal))
                                        (when (buffer-live-p buff)
                                          (funcall update-fn))))))
            (set-process-filter
             proc
             (lambda
               (process str)
               (ignore-errors
                 (let ((buff (process-buffer process)))
                   (when (buffer-live-p buff)
                     (with-current-buffer buff
                       (insert str))
                     (let ((update-enabled (time-less-p
                                            (list 0 0
                                                  time-to-wait)
                                            (time-since
                                             async-time))))
                       (when update-enabled
                         (condition-case nil
                             (progn (funcall update-fn)
                                    (setq async-time (current-time))
                                    (setq time-to-wait (+ 500000 time-to-wait)))
                           (error
                            (setq async-time (current-time))
                            (setq time-to-wait (* time-to-wait
                                                  time-to-wait)))))))))))
            (progn (display-buffer output-buffer)
                   (elfai--completing-read-with-preview
                    (or prompt "Image: ")
                    (lambda (string pred action)
                      (if (eq action 'metadata)
                          `(metadata
                            (annotation-function
                             .
                             ,annotf))
                        (complete-with-action
                         action
                         (mapcar #'car alist)
                         string
                         pred)))
                    #'elfai--minibuffer-preview-file-action
                    elfai--multi-source-minibuffer-map
                    #'file-exists-p)))
        (kill-buffer output-buffer)))))


(defun elfai-get-xdg-dirs ()
  "Return a list of user directories from the XDG configuration file."
  (when
      (require 'xdg nil t)
    (when (and (fboundp 'xdg--user-dirs-parse-file)
               (fboundp 'xdg-config-home))
      (ignore-errors (mapcar #'cdr
                             (xdg--user-dirs-parse-file
                              (expand-file-name "user-dirs.dirs"
                                                (xdg-config-home))))))))

(defun elfai--completing-read-image ()
  "Choose an image file with completion and preview."
  (let* ((dirs (append (elfai--get-active-directories)
                       (elfai-get-xdg-dirs)))
         (files (elfai--files-to-sorted-alist
                 (mapcan
                  (lambda (dir)
                    (directory-files
                     dir t
                     (concat "\\."
                             (regexp-opt
                              elfai-image-allowed-file-extensions)
                             "\\'")))
                  (if (member (expand-file-name elfai-images-dir) dirs)
                      dirs
                    (seq-filter
                     #'file-exists-p
                     (nconc dirs (list elfai-images-dir)))))))
         (annotf
          (lambda (file)
            (concat (propertize " " 'display (list 'space :align-to 80))
                    (elfai--format-time-diff (cdr (assoc-string file
                                                                files))))))
         (category 'file))
    (elfai--completing-read-with-preview
     "Image: "
     (lambda (str pred action)
       (if (eq action 'metadata)
           `(metadata
             (annotation-function . ,annotf)
             (category . ,category))
         (complete-with-action action files
                               str pred)))
     #'elfai--minibuffer-preview-file-action)))

(defun elfai--read-image-from-multi-sources (&optional arg)
  "Choose an image from multiple sources with minibuffer completion.
With optional ARG \\='(16), make the file name relative in the link."
  (let ((file (elfai--completing-read-from-multi-source
               '((elfai--completing-read-image)
                 (elfai--read-image-file-name)
                 (elfai--fdfind-completing-read)))))
    (cond ((equal arg '(16))
           (let ((relative (file-relative-name file
                                               default-directory)))
             (unless (or (string-prefix-p "./" relative)
                         (string-prefix-p "../" relative))
               (setq relative (concat "./" relative)))
             relative))
          (t file))))

(defun elfai--read-image-file-name ()
  "Prompt user to select a PNG image file."
  (elfai--read-file-name "Image: " nil nil nil nil
                         (lambda (file)
                           (or (file-directory-p file)
                               (member (file-name-extension file)
                                       elfai-image-allowed-file-extensions)))))


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
         (preview-action
          (lambda (file)
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
              (add-hook 'after-change-functions
                        (lambda (&rest _)
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
                      (propertize " " 'display `(space :align-to
                                                 ,(or align 40)))
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
  (cond ((and (not noninteractive)
              (yes-or-no-p (format "Save %s with value %s?" var-sym value)))
         (customize-save-variable var-sym value
                                  "Saved by elfai-set-or-save-variable"))
        ((local-variable-p var-sym)
         (set var-sym value)
         (message
          (or comment
              (format
               "Variable's %s value is setted to %s locally in buffer %s"
               var-sym value
               (current-buffer)))))
        ((get var-sym 'custom-set)
         (funcall (get var-sym 'custom-set)
                  var-sym
                  value)
         (message (or comment (format "Variable's %s value is setted to %s"
                                      var-sym value))))
        (t (set-default
            var-sym
            value)
           (message (or comment (format "Variable's %s value is setted to %s"
                                        var-sym value)))))
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
  "Set `elfai-model' to MODEL.

Argument MODEL is the name of the GPT model to set."
  (interactive (list
                (elfai--completing-read-model "Model: ")))
  (elfai-set-model 'elfai-model model))


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
      (setq content (string-trim-left
                     (substring-no-properties content (length prefix)))))
    (when (and suffix (string-suffix-p suffix content))
      (setq content (string-trim-right
                     (substring-no-properties content 0
                                              (- (length content)
                                                 (length suffix))))))
    content))

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
  "Prepare the content of buffer before point and send it to AI model.

This function prepares the buffer content and sends it to the AI model for
processing.

It handles the expansion of file links to their content,ensuring that the
content sent to the model is accurate and up-to-date.

During completion ongoing request can be cancelled by pressing `keyboard-quit'
multiple times,as specified by the `elfai-abort-on-keyboard-quit-count'
variable.

The default value is 5, meaning that pressing `keyboard-quit` five
times in quick succession will abort the request.

Related Custom Variables:
- `elfai-abort-on-keyboard-quit-count': Number of `keyboard-quit' presses before
  aborting GPT requests.
- `elfai-before-parse-buffer-hook': A hook that runs before parsing the buffer
  for AI model completion.
- `elfai-image-allowed-file-extensions': List of allowed file extensions for
  image files."
  (interactive)
  (let ((inserter
         (if (and
              (derived-mode-p 'org-mode)
              (bound-and-true-p org-indent-mode)
              (fboundp 'org-indent-refresh-maybe))
             (lambda (it)
               (let ((beg (point)))
                 (insert it)
                 (org-indent-refresh-maybe beg (point) nil)))
           #'insert))
        (req-data (elfai--get-request-data)))
    (save-excursion
      (elfai--presend)
      (elfai--update-status " Waiting" 'warning t)
      (elfai--stream-request
       req-data
       (lambda ()
         (elfai--update-status " Ready" 'success))
       nil
       nil
       :error-callback (lambda (err)
                         (elfai--update-status
                          (truncate-string-to-width
                           (format
                            " Error: %s"
                            err)
                           60)
                          'error))
       :inserter inserter))))

(defun elfai--get-request-data ()
  "Run hooks, parse buffer, and return request data with messages."
  (run-hooks 'elfai-before-parse-buffer-hook)
  (let ((messages (save-excursion
                    (elfai--parse-buffer)))
        (req-data (list
                   :model elfai-model
                   :temperature elfai-temperature
                   :stream t)))
    (plist-put req-data :messages
               (apply #'vector
                      (cons (list
                             :role "system"
                             :content
                             (or
                              (elfai-system-prompt)
                              ""))
                            messages)))))

(defun elfai-inspect-request-data (&optional arg)
  "Display request data in a buffer, optionally pretty-printing JSON.

Optional argument ARG is a prefix argument used to determine the behavior of the
function."
  (interactive "P")
  (require 'json)
  (let ((request-data (elfai--get-request-data))
        (buff-name "*elfai-req-data*"))
    (if arg
        (with-current-buffer (get-buffer-create buff-name)
          (buffer-disable-undo)
          (fundamental-mode)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (elfai--json-encode request-data))
            (json-pretty-print-buffer))
          (setq buffer-read-only t)
          (display-buffer (current-buffer)))
      (with-output-to-temp-buffer buff-name
        (let ((inhibit-read-only t)
              (res (or
                    (ignore-errors (pp-to-string
                                    request-data))
                    (prin1-to-string request-data))))
          (princ res standard-output)
          (with-current-buffer standard-output
            (buffer-disable-undo)
            (let ((lisp-data-mode-hook nil))
              (lisp-data-mode)
              (font-lock-ensure))
            (setq buffer-read-only t)))))))


(defun elfai--get-major-mode (filename)
  "Return the major mode associated with FILENAME, either from buffer or file.

Argument FILENAME is the filename of the file for which to determine the major
mode."
  (or
   (when-let ((buff
               (get-file-buffer filename)))
     (buffer-local-value 'major-mode buff))
   (let ((fname (if (file-name-absolute-p filename)
                    filename
                  (expand-file-name filename default-directory))))
     (with-temp-buffer
       (ignore-errors
         (let ((inhibit-message t)
               (message-log-max nil)
               (buffer-file-name fname))
           (delay-mode-hooks (set-auto-mode t)
                             major-mode)))))))


(defun elfai--major-mode-to-lang-name (sym)
  "Return language name corresponding to the major mode symbol SYM.

Argument SYM is the symbol representing the major mode."
  (or
   (when (boundp 'markdown-code-lang-modes)
     (car (rassq sym markdown-code-lang-modes)))
   (let ((name
          (replace-regexp-in-string "\\(-ts\\)?-mode$" "" (symbol-name sym))))
     (or
      (elfai-get-org-language sym)
      (replace-regexp-in-string "fundamental" "" name)))))

(defun elfai--copy-file-to-attachment-dir (file-path)
  "Copy FILE-PATH to `elfai-attachment-dir` and return the new path."
  (let* ((file-name (file-name-nondirectory file-path))
         (dest-dir (expand-file-name elfai-attachment-dir))
         (dest-path))
    (unless (file-directory-p dest-dir)
      (make-directory dest-dir t))
    (setq dest-path (elfai--uniqify-filename-with-counter
                     (expand-file-name file-name
                                       dest-dir)
                     dest-dir))
    (copy-file file-path dest-path
               t)
    dest-path))


(defun elfai--parse-buffer-data ()
  "Parse buffer content, extracting and categorizing text and links into data."
  (require 'org)
  (let ((data)
        (link-re (org-link-make-regexps))
        (content-beg (point-min))
        (content-end)
        (content))
    (save-excursion
      (goto-char (point-min))
      (let ((add-text-elem
             (lambda (str)
               (unless (string-empty-p str)
                 (let ((prev-elem (car-safe data))
                       (text (or
                              (elfai--include-files str)
                              str)))
                   (cond ((and prev-elem
                               (plist-get prev-elem :type)
                               (equal (plist-get prev-elem :type)
                                      "text"))
                          (setq prev-elem (plist-put
                                           prev-elem
                                           :text
                                           (concat
                                            (plist-get prev-elem :text)
                                            text))))
                         (t (push `(:type "text"
                                    :text ,text)
                                  data))))))))
        (while (re-search-forward link-re nil t 1)
          (let ((link (or (match-string-no-properties 2)
                          (match-string-no-properties 1)
                          (match-string-no-properties 0)))
                (beg (match-beginning 0))
                (end (match-end 0))
                (description (match-string-no-properties 3)))
            (let ((file
                   (when link
                     (let ((link-path (replace-regexp-in-string
                                       org-link-types-re
                                       "" link)))
                       (when (and (not (string-empty-p link-path))
                                  (file-exists-p link-path)
                                  (not (file-directory-p link-path)))
                         link-path)))))
              (setq content-end (if file beg end))
              (setq content (string-trim
                             (buffer-substring-no-properties content-beg
                                                             content-end)))
              (setq content-beg end)
              (setq content-end nil)
              (funcall add-text-elem content)
              (cond ((or (not file)
                         (member (file-name-extension file)
                                 elfai-non-embeddable-file-extensions)))
                    ((member (file-name-extension file)
                             elfai-image-allowed-file-extensions)
                     (let ((props `(:type
                                    "image_url"
                                    :image_url
                                    (:url
                                     ,(elfai--encode-image
                                       (replace-regexp-in-string
                                        org-link-types-re
                                        "" file))))))
                       (push props data)))
                    (t
                     (let* ((text (concat
                                   (or description link file)
                                   ":\n"
                                   (let ((lang
                                          (elfai--major-mode-to-lang-name
                                           (elfai--get-major-mode
                                            file))))
                                     (with-temp-buffer
                                       (insert-file-contents file)
                                       (concat "```" lang "\n"
                                               (buffer-string)
                                               "\n```")))))
                            (props `(:type "text"
                                     :text ,text)))
                       (push props data)))))))
        (setq content (string-trim
                       (buffer-substring-no-properties (point) (point-max))))
        (funcall add-text-elem content)))
    (nreverse data)))


(declare-function org-export-expand-include-keyword "ox")

(defun elfai--include-files-with-org-export (content)
  "Expand included files in Org CONTENT and return result.

Argument CONTENT is a string containing the text with `org-mode' include
keywords to be expanded."
  (require 'org)
  (require 'ox)
  (with-temp-buffer
    (let ((tab-width 8))
      (insert content)
      (condition-case err
          (progn (org-export-expand-include-keyword)
                 (buffer-substring-no-properties
                  (point-min)
                  (point-max)))
        (error (message "Elfai: Couldn't expand #+INCLUDE directive: %s" err)
               content)))))

(defun elfai--include-files (content)
  "Insert the contents of included files into the buffer at matching directives.

Argument CONTENT is the string containing the text to process."
  (when-let ((regex (elfai--make-include-directives-regex)))
    (with-temp-buffer
      (insert content)
      (let ((case-fold-search t))
        (while (re-search-backward
                regex
                (point-min) t
                1)
          (let* ((value (match-string-no-properties 2))
                 (beg (match-beginning 0))
                 (end (match-end 0))
                 (params (elfai--parse-include-value value))
                 (link-path (plist-get params :file)))
            (when (and link-path (file-readable-p link-path))
              (let ((block (plist-get params :block)))
                (delete-region beg end)
                (when block
                  (insert (upcase (concat "#+begin_" block "\n")))
                  (save-excursion
                    (insert (upcase (concat "#+end_" block "\n")))))
                (insert-file-contents link-path))))))
      (buffer-string))))


(defun elfai--unbracket-string (pre post string)
  "Remove PRE/POST from the beginning/end of STRING.
Both PRE and POST must be pre-/suffixes of STRING, or neither is
removed.  Return the new string.  If STRING is nil, return nil."
  (declare (indent 2))
  (and string
       (if (and (string-prefix-p pre string)
                (string-suffix-p post string))
           (substring string (length pre)
                      (and (not (string-equal "" post)) (- (length post))))
         string)))

(defun elfai--strip-quotes (string)
  "Strip double quotes from around STRING, if applicable.
If STRING is nil, return nil."
  (elfai--unbracket-string "\"" "\"" string))

(defvar ffap-url-regexp)

(defun elfai--url-p (s)
  "Non-nil if string S is a URL."
  (require 'ffap)
  (and ffap-url-regexp (string-match-p ffap-url-regexp s)))

(defun elfai--parse-include-value (value)
  "Extract the various parameters from #+include: VALUE.

More specifically, this extracts the following parameters to a
plist: :file, :coding-system, :location, :only-contents, :lines,
:env, :minlevel, :args, and :block.

The :file parameter is expanded relative to DIR.

The :file, :block, and :args parameters are extracted
positionally, while the remaining parameters are extracted as
plist-style keywords."
  (let* (location
         (coding-system
          (and (string-match ":coding +\\(\\S-+\\)>" value)
               (prog1 (intern (match-string 1 value))
                 (setq value (replace-match "" nil nil value)))))
         (file
          (and (string-match "^\\(\".+?\"\\|\\S-+\\)\\(?:\\s-+\\|$\\)" value)
               (let ((matched (match-string 1 value)))
                 (setq value (replace-match "" nil nil value))
                 (when (string-match "\\(::\\(.*?\\)\\)\"?\\'"
                                     matched)
                   (setq location (match-string 2 matched))
                   (setq matched
                         (replace-match "" nil nil matched 1)))
                 (elfai--strip-quotes matched))))
         (only-contents
          (and (string-match ":only-contents *\\([^: \r\t\n]\\S-*\\)?"
                             value)
               (prog1
                   (let ((v (match-string 1 value)))
                     (and v (not (equal v "nil")) v))
                 (setq value (replace-match "" nil nil value)))))
         (lines
          (and (string-match
                ":lines +\"\\([0-9]*-[0-9]*\\)\""
                value)
               (prog1 (match-string 1 value)
                 (setq value (replace-match "" nil nil value)))))
         (env
          (cond ((string-match "\\<example\\>" value) 'literal)
                ((string-match "\\<export\\(?: +\\(.*\\)\\)?" value)
                 'literal)
                ((string-match "\\<src\\(?: +\\(.*\\)\\)?" value)
                 'literal)))
         (args (and (eq env 'literal)
                    (prog1 (match-string 1 value)
                      (when (match-string 1 value)
                        (setq value (replace-match "" nil nil value 1))))))
         (block (and (or (string-match "\"\\(\\S-+\\)\"" value)
                         (string-match "\\<\\(\\S-+\\)\\>" value))
                     (or (= (match-beginning 0) 0)
                         (not (= ?: (aref value (1- (match-beginning 0))))))
                     (prog1 (match-string 1 value)
                       (setq value (replace-match "" nil nil value))))))
    (list
     :file file
     :coding-system coding-system
     :location location
     :only-contents only-contents
     :lines lines
     :env env
     :args args
     :block block)))

(defun elfai--normalize-directive (directive)
  "Return normalized DIRECTIVE with \"#+\" prefix and \":\" suffix.

Argument DIRECTIVE is the string to be normalized."
  (let ((trimmed (string-trim directive)))
    (unless (string-prefix-p "#+" trimmed)
      (setq trimmed (concat "#+" trimmed)))
    (unless (string-suffix-p ":" trimmed)
      (setq trimmed (concat trimmed ":")))
    trimmed))
(defun elfai--make-copy-directives-regex ()
  "Generate a regex for matching copy directives.

See variable `elfai-allowed-include-directives'"
  (when-let ((directives (mapcar
                          (lambda (it)
                            (let ((trimmed (string-trim it)))
                              (unless (string-prefix-p "#+" trimmed)
                                (setq trimmed (concat "#+" trimmed)))
                              (unless (string-suffix-p ":" trimmed)
                                (setq trimmed (concat trimmed ":")))
                              (regexp-quote trimmed)))
                          (cdr (assq 'copy elfai-allowed-include-directives)))))
    (concat
     "^[ \t]*"
     "\\("
     (string-join directives "\\|")
     "\\)"
     "[ \t]*\\([^\n]+\\)")))

(defun elfai--make-include-directives-regex ()
  "Return a regex matching allowed include directives.
See variable `elfai-allowed-include-directives'."
  (when-let ((directives (mapcar
                          (lambda (it)
                            (let ((trimmed (string-trim it)))
                              (unless (string-prefix-p "#+" trimmed)
                                (setq trimmed (concat "#+" trimmed)))
                              (unless (string-suffix-p ":" trimmed)
                                (setq trimmed (concat trimmed ":")))
                              (regexp-quote trimmed)))
                          (delete-dups
                           (seq-reduce (lambda (acc it)
                                         (setq acc (append acc (cdr it))))
                                       elfai-allowed-include-directives
                                       '())))))
    (concat
     "^[ \t]*"
     "\\("
     (string-join directives "\\|")
     "\\)"
     "[ \t]*\\([^\n]+\\)")))

(defun elfai-copy-and-replace-include-directives ()
  "Copy files referenced by include directives to a specified directory."
  (when-let ((regex (elfai--make-copy-directives-regex)))
    (let (prop)
      (save-excursion
        (while (and
                (setq prop (text-property-search-backward
                            'elfai 'response
                            (when (get-char-property
                                   (max (point-min) (1- (point)))
                                   'elfai)
                              t))))
          (unless (prop-match-value prop)
            (let ((user-start (prop-match-beginning prop))
                  (user-end (prop-match-end prop))
                  (case-fold-search t))
              (save-excursion
                (goto-char user-end)
                (while (re-search-backward
                        regex
                        user-start t
                        1)
                  (let* ((value (match-string-no-properties 2))
                         (end (match-end 2))
                         (link-path (and (string-match
                                          "^\\(\".+?\"\\|\\S-+\\)\\(?:\\s-+\\|$\\)"
                                          value)
                                         (let ((matched (match-string 1 value)))
                                           (setq value (replace-match "" nil nil value))
                                           (when (string-match
                                                  "\\(::\\(.*?\\)\\)\"?\\'"
                                                  matched)
                                             (setq matched
                                                   (replace-match "" nil nil matched 1)))
                                           (elfai--strip-quotes matched)))))
                    (when (and link-path
                               (and (not (string-empty-p link-path))
                                    (file-readable-p link-path)
                                    (file-exists-p link-path)
                                    (not
                                     (file-in-directory-p
                                      link-path
                                      elfai-attachment-dir))
                                    (not (file-directory-p link-path))))
                      (let ((re (regexp-quote link-path))
                            (full-path (elfai--copy-file-to-attachment-dir
                                        (expand-file-name
                                         link-path))))
                        (save-excursion
                          (when (re-search-forward re end t 1)
                            (replace-match full-path)))))))))))))))


(defun elfai--get-dired-marked-files ()
  "Retrieve marked files from the active `dired-mode' buffer."
  (require 'dired)
  (when (fboundp 'dired-get-marked-files)
    (when-let ((buff (seq-find (lambda
                                 (buff)
                                 (and (eq (buffer-local-value 'major-mode buff)
                                          'dired-mode)
                                      (get-buffer-window buff)
                                      (with-current-buffer buff
                                        (dired-get-marked-files))))
                               (delete-dups (append (mapcar #'window-buffer
                                                            (window-list))
                                                    (buffer-list))))))
      (with-current-buffer buff
        (dired-get-marked-files)))))

(defun elfai--get-files-recoursively (files-or-dirs)
  "Retrieve all files from given directories and files list recursively.

Argument FILES-OR-DIRS is a list of files or directories."
  (let ((files))
    (dolist (file files-or-dirs)
      (if (file-directory-p file)
          (setq files
                (nconc files
                       (elfai--get-files-recoursively
                        (directory-files
                         file
                         t
                         directory-files-no-dot-files-regexp))))
        (push file files)))
    (nreverse files)))

(defun elfai--get-files-dwim ()
  "Return a list of marked files in `dired' or the current buffer's file name."
  (or (elfai--get-files-recoursively
       (elfai--get-dired-marked-files))
      (and buffer-file-name (list buffer-file-name))))


;;;###autoload
(defun elfai-copy-files-paths-as-include-directives (directive)
  "Copy file paths as include directives with a specified directive.

Argument DIRECTIVE is the string representing the include directive to use.

See also `elfai-allowed-include-directives'."
  (interactive
   (list (completing-read "Directive: "
                          (mapcar (lambda (it)
                                    (replace-regexp-in-string "^#\\+"
                                                              ""
                                                              (elfai--normalize-directive
                                                               it)))
                                  (delete-dups
                                   (seq-reduce (lambda (acc it)
                                                 (setq acc (append acc (cdr it))))
                                               elfai-allowed-include-directives
                                               '()))))))
  (let* ((files (elfai--get-files-dwim))
         (str (mapconcat
               (apply-partially
                #'elfai--file-path-as-include-directive
                (elfai--normalize-directive directive))
               files
               "\n\n")))
    (kill-new str)
    (message "Copied content of %s files" (length files))
    str))

;;;###autoload
(defun elfai-copy-files-paths-as-org-links ()
  "Copy the paths of marked files as Org-mode links to the clipboard."
  (interactive)
  (let* ((files (elfai--get-files-dwim))
         (str (mapconcat #'elfai--format-file-path-as-link files "\n\n")))
    (kill-new str)
    (message "Copied content of %s files" (length files))
    str))

;;;###autoload
(defun elfai-copy-files-as-links-or-include-directive (&optional arg)
  "Copy files contents as either Org links or #+INCLUDE directives.

In `dired' use marked files, otherwise current buffer file.

If optional prefix argument ARG is non-nil, copy file contents as Org links,

With the prefix argument ARG copy file contents as Org links. If not provided,
copy as #+INCLUDE directives."
  (interactive "P")
  (if arg
      (elfai-copy-files-paths-as-include-directives
       (completing-read "Directive: "
                        (mapcar (lambda (it)
                                  (replace-regexp-in-string "^#\\+"
                                                            ""
                                                            (elfai--normalize-directive
                                                             it)))
                                (delete-dups
                                 (seq-reduce
                                  (lambda (acc it)
                                    (setq acc (append acc (cdr it))))
                                  (reverse elfai-allowed-include-directives)
                                  '())))))
    (elfai-copy-files-paths-as-include-directives
     (cadar elfai-allowed-include-directives))))

(defun elfai--file-path-as-include-directive (directive file)
  "Return a string with an include directive and the path to FILE.

Argument DIRECTIVE is a string representing the directive to be included.

Argument FILE is the path to the file whose content is to be included."
  (require 'project)
  (let* ((parent-dir (file-name-parent-directory file))
         (proj (ignore-errors
                 (when (fboundp 'project-root)
                   (project-root
                    (project-current nil parent-dir)))))
         (title (if proj
                    (substring-no-properties
                     (expand-file-name file)
                     (length (expand-file-name proj)))
                  (abbreviate-file-name file)))
         (content
          (concat
           (format "%s %s" directive (prin1-to-string file))
           " "
           "EXAMPLE")))
    (concat "- " title "\n"
            "\n"
            content
            "\n\n")))

(defun elfai--format-file-path-as-link (file)
  "Format FILE as an Org-mode link with its project-relative or abbreviated path.

Argument FILE is the path of the file to be formatted as a link."
  (require 'project)
  (let* ((parent-dir (file-name-parent-directory file))
         (proj (ignore-errors
                 (when (fboundp 'project-root)
                   (project-root
                    (project-current nil parent-dir)))))
         (title (if proj
                    (substring-no-properties
                     (expand-file-name file)
                     (length (expand-file-name proj)))
                  (abbreviate-file-name file))))
    (concat "- " (format "[[%s][%s]]" file title) "\n" "\n")))

(defun elfai--expand-content (content)
  "Expand CONTENT into a vector of parsed data elements.

Argument CONTENT is the string containing the content to be expanded."
  (let ((data (with-temp-buffer
                (insert content)
                (elfai--parse-buffer-data))))
    (apply #'vector data)))

(defun elfai-copy-and-replace-user-links ()
  "Replace user links with new paths after copying files to the elfai directory."
  (require 'org)
  (let ((prop)
        (link-re (org-link-make-regexps)))
    (save-excursion
      (while (and
              (setq prop (text-property-search-backward
                          'elfai 'response
                          (when (get-char-property
                                 (max (point-min) (1- (point)))
                                 'elfai)
                            t))))
        (unless (prop-match-value prop)
          (let ((user-start (prop-match-beginning prop))
                (user-end (prop-match-end prop)))
            (save-excursion
              (goto-char user-end)
              (while (re-search-backward link-re user-start t 1)
                (let ((full-link (match-string-no-properties 0))
                      (link (or (match-string-no-properties 2)
                                (match-string-no-properties 1)
                                (match-string-no-properties 0)))
                      (beg (match-beginning 0))
                      (end (match-end 0)))
                  (let ((file
                         (when link
                           (let ((link-path (replace-regexp-in-string
                                             org-link-types-re
                                             "" link)))
                             (when (and (not (string-empty-p link-path))
                                        (not
                                         (member (file-name-extension
                                                  link-path)
                                                 elfai-image-allowed-file-extensions))
                                        (file-exists-p link-path)
                                        (not
                                         (file-in-directory-p
                                          link-path
                                          elfai-attachment-dir))
                                        (not (file-directory-p link-path)))
                               link-path)))))
                    (when file
                      (let ((re (regexp-quote file))
                            (full-path (elfai--copy-file-to-attachment-dir
                                        (expand-file-name
                                         file)))
                            (rep))
                        (setq rep
                              (replace-regexp-in-string re full-path full-link))
                        (delete-region beg end)
                        (insert rep)))))))))))))



(defun elfai--parse-buffer ()
  "Parse buffer for gpt vision model."
  (let ((prompts)
        (prop))
    (while (and
            (setq prop (text-property-search-backward
                        'elfai 'response
                        (when (get-char-property
                               (max (point-min) (1- (point)))
                               'elfai)
                          t))))
      (let* ((role (if (prop-match-value prop)
                       "assistant" "user"))
             (content (buffer-substring-no-properties
                       (prop-match-beginning
                        prop)
                       (prop-match-end
                        prop)))
             (normalized-content
              (funcall (if (string= role "assistant")
                           #'elfai--normalize-assistent-prompt
                         #'elfai--expand-content)
                       content)))
        (unless (and normalized-content
                     (stringp normalized-content)
                     (string-blank-p
                      normalized-content))
          (push
           (list
            :role role
            :content normalized-content)
           prompts))))
    (elfai--debug 'parse-buffer "%S" prompts)
    prompts))

(defun elfai-get-header-line ()
  "Display a header line with model info and interactive buttons."
  (list
   '(:eval (concat (propertize " " 'display '(space :align-to 0))
            (format "%s" elfai-model)))
   (propertize " Ready" 'face 'success)
   '(:eval
     (let* ((l1 (length elfai-model))
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
        (buttonize (concat "[" elfai-model "]")
         (lambda (&rest _)
           (elfai-menu)))
        'mouse-face 'highlight
        'help-echo "GPT model in use"))))))


(defun elfai-update-header (msg face)
  "Update the second element of `header-line-format' with a propertized message.

Argument MSG is the message to be displayed in the header.

Argument FACE is the face to be applied to the message.

Optional argument _LOADING is an unused parameter."
  (when (consp header-line-format)
    (setf (nth 1 header-line-format)
          (propertize msg 'face face))))

(defun elfai-update-mode-line-process (msg face)
  "Update the mode-line process with MSG and FACE, optionally indicating LOADING.

Argument MSG is the message to display in the mode line.

Argument FACE is the face property to apply to the message.

Optional argument LOADING is a boolean indicating whether to show the loading
message."
  (if elfai-loading
      (setq mode-line-process (propertize msg 'face face))
    (setq mode-line-process
          '(:eval (concat " "
                   (buttonize elfai-model
                    (lambda (&rest _) (elfai-menu))))))))

(defun elfai--update-status (&optional msg face loading)
  "Update the status indicator with MSG and FACE based on the current mode.

Optional argument MSG is the message to be displayed.

Optional argument FACE is the face property to style the message.

Optional argument LOADING is a boolean indicating if a loading state should be
shown."
  (when (elfai-minor-mode-p 'elfai-mode)
    (setq elfai-loading loading)
    (run-hook-with-args 'elfai-status-indicator msg face)))

;;;###autoload
(defalias 'elfai-region-convervation #'elfai)

;;;###autoload
(defun elfai (&optional text buff-name)
  "Start or switch to a chat session in the buffer BUFF-NAME.

Optional argument TEXT is the text to be inserted at the top of the buffer.

Optional argument BUFF-NAME is the name of the buffer where the initial
TEXT will be inserted and `elfai-mode' activated, as well as `org-mode'."
  (interactive
   (list (elfai-get-region)
         (let ((buffs (elfai--get-elfai-buffers)))
           (if (or current-prefix-arg
                   (length> buffs 1))
               (elfai--read-buffer  "Buffer: ")
             (or (car buffs)
                 "*Elfai response*")))))
  (let* ((lang
          (when text (elfai-get-org-language
                      major-mode)))
         (wind-pos)
         (buffer (with-current-buffer
                     (get-buffer-create
                      (or buff-name
                          "*Elfai response*"))
                   (unless (symbol-value 'elfai-mode)
                     (elfai-mode))
                   (setq-local elfai-model elfai-model)
                   (cond (text
                          (goto-char (point-min))
                          (let ((pos
                                 (save-excursion
                                   (when (looking-at (regexp-quote
                                                      elfai-user-prompt-prefix))
                                     (re-search-forward
                                      (regexp-quote
                                       elfai-user-prompt-prefix)
                                      nil t 1)))))
                            (if (and pos
                                     (string-empty-p
                                      (string-trim
                                       (buffer-substring-no-properties
                                        pos
                                        (point-max)))))
                                (goto-char pos)
                              (insert elfai-user-prompt-prefix)))
                          (setq wind-pos (point))
                          (save-excursion
                            (insert "\n\n"
                                    (if (not text)
                                        ""
                                      (if lang
                                          (concat (concat "#+begin_src " lang
                                                          "\n"
                                                          text "\n"
                                                          "#+end_src"))
                                        (concat "#+begin_example\n" text
                                                "\n#+end_example")))
                                    "\n\n"))))
                   (current-buffer))))
    (let ((wnd (or (get-buffer-window buffer)
                   (elfai--get-other-wind))))
      (select-window wnd)
      (pop-to-buffer-same-window buffer)
      (when wind-pos
        (set-window-point wnd wind-pos)))
    buffer))

(defun elfai--get-other-wind ()
  "Return another window or split sensibly if needed."
  (let ((wind-target
         (if (minibuffer-selected-window)
             (with-minibuffer-selected-window
               (let ((wind (selected-window)))
                 (or
                  (window-right wind)
                  (window-left wind)
                  (split-window-sensibly)
                  wind)))
           (let ((wind (selected-window)))
             (or
              (window-right wind)
              (window-left wind)
              (split-window-sensibly)
              wind)))))
    wind-target))

(defun elfai--get-elfai-buffers ()
  "Return a list of buffers where `elfai-mode' is active."
  (let ((buffers))
    (dolist (buff (buffer-list))
      (when (buffer-local-value 'elfai-mode buff)
        (push buff buffers)))
    buffers))

(defun elfai--minibuffer-preview-buffer-action (buffer)
  "Preview a BUFFER in the minibuffer if conditions are met.

Argument BUFFER is the path to the buffer to preview."
  (setq buffer (get-buffer buffer))
  (when (and buffer
             (buffer-live-p buffer))
    (unless (get-buffer-window
             buffer)
      (with-selected-window
          (let ((wind
                 (selected-window)))
            (or
             (window-right wind)
             (window-left wind)
             (split-window-sensibly) wind))
        (pop-to-buffer-same-window buffer)))))

(defun elfai--read-buffer (prompt &optional keymap predicate)
  "PROMPT for a buffer name from a list of buffers with `elfai-mode'.

Argument PROMPT is a string used to prompt the user.

Optional argument KEYMAP is a keymap to use during completion.

Optional argument PREDICATE is a function to filter buffer names."
  (let* ((buffers (elfai--get-elfai-buffers))
         (buff-names (mapcar #'buffer-name buffers))
         (category 'buffer))
    (elfai--completing-read-with-preview
     prompt
     (lambda (str pred action)
       (if (eq action 'metadata)
           `(metadata
             (category . ,category))
         (complete-with-action action
                               buff-names
                               str pred)))
     #'elfai--minibuffer-preview-buffer-action
     keymap
     predicate)))

(defun elfai-switch-to-buffer ()
  "Switch to another window displaying a buffer selected via completion."
  (interactive)
  (switch-to-buffer-other-window
   (elfai--read-buffer "Buffer: ")))


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
  (let ((errors (seq-sort-by
                 (pcase-lambda (`(,_k ,v . _)) v)
                 #'>
                 (delq nil
                       (mapcar #'elfai--get-error-from-overlay
                               (overlays-in (point-min)
                                            (point-max))))))
        (orig-content (buffer-string))
        (pos (point))
        (content))
    (setq content (catch 'content
                    (pcase-dolist (`(,text ,beg) errors)
                      (save-excursion (goto-char beg)
                                      (let ((end)
                                            (stx (syntax-ppss beg)))
                                        (when (nth 3 stx)
                                          (goto-char (nth 8 stx))
                                          (forward-sexp)
                                          (setq beg (point)))
                                        (insert text)
                                        (setq end (point))
                                        (goto-char beg)
                                        (ignore-errors
                                          (comment-region beg end)))))
                    (throw 'content (buffer-substring-no-properties
                                     (point-min)
                                     (point-max)))))
    (delete-region (point-min)
                   (point-max))
    (insert orig-content)
    (goto-char pos)
    (let ((elfai-user-prompt-prefix
           (concat elfai-user-prompt-prefix
                   "Fix the errors, described in comments")))
      (elfai content))))

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
        (elfai
         (elfai--get-content-with-cursor placeholder))))))


(defvar org-src-lang-modes)

(defun elfai-get-org-language (mode)
  "Return the corresponding Org language for a given major mode.

Argument MODE is the major mode or a string representing the mode name."
  (require 'org)
  (let* ((mode-name (if (stringp mode)
                        mode
                      (symbol-name major-mode)))
         (mode-str (replace-regexp-in-string "-mode$" "" mode-name))
         (no-ts-mode
          (replace-regexp-in-string "-\\(ts-\\)?mode$" ""
                                    mode-name)))
    (car (seq-find (pcase-lambda (`(,lang . ,v))
                     (let ((str (if (stringp v)
                                    v
                                  (format "%s" v)))
                           (lang-str (if (stringp lang)
                                         lang
                                       (format "%s" lang))))
                       (or (string= str mode-str)
                           (string= str no-ts-mode)
                           (string= mode-str lang-str)
                           (string= no-ts-mode lang-str))))
                   org-src-lang-modes))))


(define-minor-mode elfai-abort-mode
  "Toggle monitoring `keyboard-quit' commands for aborting GPT requests.

Enable `elfai-abort-mode' to monitor and handle `keyboard-quit'
commands for aborting GPT requests.

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
  "Return the current system prompt from `elfai-system-prompt-alist'."
  (cdr (nth elfai-curr-prompt-idx elfai-system-prompt-alist)))

(defun elfai--get-buffer-bounds ()
  "Return the elfai response boundaries in the buffer as an alist."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-max))
      (let ((prop)
            (bounds))
        (while (setq prop (text-property-search-backward
                           'elfai 'response t))
          (push (cons (prop-match-beginning prop)
                      (prop-match-end prop))
                bounds))
        bounds))))

(defun elfai--restore-state (&rest _)
  "Restore text properties for response regions in `elfai--bounds' list."
  (remove-hook 'org-font-lock-hook #'elfai--restore-state t)
  (when (buffer-file-name)
    (pcase-dolist (`(,beg . ,end) elfai--bounds)
      (add-text-properties beg end elfai-props-indicator))))

(defun elfai--save-state ()
  "Write the gptel state to the buffer.

This enables saving the chat session when writing the buffer to
disk.  To restore a chat session, turn on `gptel-mode' after
opening the file."
  (save-excursion
    (save-restriction
      (widen)
      (let ((items `(elfai-model elfai-temperature
                     elfai-curr-prompt-idx
                     elfai-system-prompt-alist
                     (eval . ,`(progn
                                 (require 'elfai)
                                 (elfai-mode 1))))))
        (dolist (item items)
          (pcase item
            ((pred (symbolp))
             (add-file-local-variable item (symbol-value item)))
            (`(eval . ,value)
             (let ((regex
                    (concat "^" (string-trim (or comment-start "#"))
                            " eval: "
                            (regexp-quote
                             (prin1-to-string
                              value)))))
               (unless (save-excursion
                         (save-restriction
                           (widen)
                           (goto-char (point-max))
                           (re-search-backward regex nil t 1)))
                 (add-file-local-variable (car item) value)))))))
      (add-file-local-variable 'elfai--bounds (elfai--get-buffer-bounds)))))


(defun elfai--uniqify-filename-with-counter (file dest-dir)
  "Generate a unique filename with a counter suffix in the specified directory.

Argument FILE is the name of the file to be processed.

Argument DEST-DIR is the directory where the FILE will be saved."
  (let* ((ext (file-name-extension file))
         (basename (file-name-base file))
         (file-regex (concat "\\`"
                             (regexp-quote basename)
                             (if ext
                                 (concat "\\(-[0-9]+\\)" "\\." ext "\\'")
                               "\\(-[0-9]+\\)\\'")))
         (max-count 0)
         (new-name))
    (dolist (filename (directory-files dest-dir
                                       nil
                                       file-regex))
      (let ((count
             (string-to-number (car (last (split-string
                                           (file-name-base
                                            filename)
                                           "-" t))))))
        (when (> count max-count)
          (setq max-count count))))
    (setq new-name (string-join
                    (delq nil (list (format "%s-%d" basename max-count)
                                    (and ext (concat "." ext))))
                    ""))
    (while (file-exists-p (expand-file-name new-name
                                            dest-dir))
      (setq max-count (1+ max-count))
      (setq new-name (string-join
                      (delq nil (list (format "%s-%d" basename max-count)
                                      (and ext (concat "." ext))))
                      "")))
    (expand-file-name new-name dest-dir)))


(defun elfai--system-prompt-description ()
  "Return a formatted string of system prompt with the current prompt highlighted."
  (let ((current (elfai-system-prompt)))
    (mapconcat (pcase-lambda (`(,label . ,value))
                 (let ((face (if (and current (string= current value))
                                 'transient-value
                               'transient-inactive-value))
                       (truncatted
                        (let ((len (string-width label))
                              (suffix "..."))
                          (prin1-to-string
                           (cond ((>= len 40)
                                  (concat (substring-no-properties label 0 40)
                                          suffix))
                                 (t (substring-no-properties label)))))))
                   (propertize truncatted 'face face)))
               elfai-system-prompt-alist (propertize "|" 'face
                                                'transient-inactive-value))))

(transient-define-suffix elfai-next-system-prompt ()
  "Choose next system prompt."
  :description (lambda ()
                 (concat "Next "
                         (elfai--system-prompt-description)))
  :inapt-if-nil 'elfai-system-prompt-alist
  :transient t
  (interactive)
  (setq elfai-curr-prompt-idx
        (elfai--index-switcher 1
                               elfai-curr-prompt-idx
                               elfai-system-prompt-alist)))

(transient-define-suffix elfai-prev-system-prompt ()
  "Choose previous system prompt."
  :inapt-if-nil 'elfai-system-prompt-alist
  :description (lambda ()
                 (concat "Prev "
                         (elfai--system-prompt-description)))
  :transient t
  (interactive)
  (setq elfai-curr-prompt-idx
        (elfai--index-switcher -1
                               elfai-curr-prompt-idx
                               elfai-system-prompt-alist)))

(transient-define-suffix elfai-add-system-prompt (&optional initial-str)
  "Add a new system prompt to `elfai-system-prompt-alist' and update the current index."
  :description "Add"
  :transient nil
  (interactive (list (elfai-get-region)))
  (string-edit
   "New system prompt: "
   (or initial-str "")
   (lambda (edited)
     (if (rassoc edited elfai-system-prompt-alist)
         (message "Such prompt already exists - `%s'"
                  (car
                   (rassoc edited
                           elfai-system-prompt-alist)))
       (let* ((label (read-string "Short description: "))
              (label-cell (assoc-string label elfai-system-prompt-alist))
              (item (cons label edited)))
         (cond ((rassoc edited elfai-system-prompt-alist))
               ((and label-cell (yes-or-no-p
                                 "This label already exists, override?"))
                (setcdr label-cell edited)
                (setq elfai-curr-prompt-idx (seq-position
                                             elfai-system-prompt-alist
                                             label-cell))
                (message "The system prompt for `%s' is changed" label))
               ((not label-cell)
                (setq elfai-system-prompt-alist
                      (push item elfai-system-prompt-alist))
                (setq elfai-curr-prompt-idx
                      (seq-position elfai-system-prompt-alist item))
                (message "The new system prompt added and setted"))))))
   :abort-callback (lambda ())))

(transient-define-suffix elfai-edit-system-prompt ()
  "Edit a system prompt to `elfai-system-prompt-alist' and update the current index."
  :description "Edit"
  :inapt-if-nil 'elfai-system-prompt-alist
  :transient nil
  (interactive)
  (let ((cell (nth elfai-curr-prompt-idx elfai-system-prompt-alist)))
    (string-edit
     (format "Edit the system prompt `%s'" (car cell))
     (cdr cell)
     (lambda (edited)
       (setcdr cell edited)
       (setcar cell (read-string "Short description: " (car cell)))
       (message "Prompt edited"))
     :abort-callback (lambda ()))))

(transient-define-suffix elfai-delete-system-prompt ()
  "Delete a system prompt to `elfai-system-prompt-alist' and update the current index."
  :description "Delete"
  :inapt-if-nil 'elfai-system-prompt-alist
  :transient t
  (interactive)
  (setq elfai-system-prompt-alist
        (remove (nth elfai-curr-prompt-idx elfai-system-prompt-alist)
                elfai-system-prompt-alist)))

;;;###autoload
(defun elfai-edit-response-wrap ()
  "Edit the response wrap formatting for the Large Language Model chat client.

This command allows to customize the prefix and suffix used to wrap the AI's
responses. The default prefix and suffix are determined by the customizable
variables `elfai-response-prefix' and `elfai-response-suffix' respectively.

When invoked, the command presents the current response wrapper format (prefix,
template placeholder, suffix) for editing. The placeholder `<<%s>>' represents
the location where the AI's response will be inserted.

After editing, the command updates the `elfai-response-prefix' and
`elfai-response-suffix' based on the newly provided values. If the new format is
invalid (i.e., missing the required placeholder), it aborts the update and
displays an error message.

Example:

If the current `elfai-response-prefix' is \"\\n\\n#+begin_src markdown\\n\" and
the `elfai-response-suffix' is \"\\n#+end_src\\n\\n\", invoking the command
would allow to edit a string that looks like this:

   \\n\\n#+begin_src markdown\\n<<%s>>\\n#+end_src\\n\\n

You can modify the prefix and suffix as needed but must retain the `<<%s>>'
placeholder.

Upon successful editing, the prefix and suffix values will be updated
accordingly."
  (interactive)
  (let ((str (concat elfai-response-prefix
                     (propertize "<<%s>>" 'face 'font-lock-keyword-face
                                 'read-only t)
                     elfai-response-suffix)))
    (string-edit
     "Edit the response wrap prefix and suffix. The placeholder `<<%s>>' represents the location where the AI's response will be inserted."
     str
     (lambda (edited)
       (let ((prefix)
             (suffix))
         (with-temp-buffer
           (insert edited)
           (when-let ((prop (text-property-search-backward 'read-only t t)))
             (setq suffix (buffer-substring (prop-match-end prop)
                                            (point-max)))
             (setq prefix (buffer-substring (point-min)
                                            (point)))))
         (if (not (and prefix suffix))
             (message "Couldn't parse string")
           (setq elfai-response-prefix prefix)
           (setq elfai-response-suffix suffix))
         (message "Updated `elfai-response-prefix' and `elfai-response-suffix'")))
     :abort-callback (lambda ()))))

(transient-define-suffix elfai-increase-temperature ()
  :description (lambda ()
                 (concat "Increase temperature "
                         (propertize
                          (format "(%s)" elfai-temperature)
                          'face
                          'transient-value)))
  :transient t
  (interactive)
  (setq elfai-temperature
        (string-to-number
         (format "%.1f"
                 (min
                  (+
                   (string-to-number
                    (format "%.1f"
                            (float (or
                                    elfai-temperature
                                    0))))
                   0.1)
                  2.0)))))

(transient-define-suffix elfai-decrease-temperature ()
  :description (lambda ()
                 (concat "Decrease temperature "
                         (propertize
                          (format "(%s)" elfai-temperature)
                          'face
                          'transient-value)))
  :transient t
  (interactive)
  (setq elfai-temperature
        (string-to-number
         (format "%.1f"
                 (max
                  (-
                   (string-to-number
                    (format "%.1f"
                            (float (or
                                    elfai-temperature
                                    0))))
                   0.1)
                  0.0)))))

(defun elfai-model-description ()
  "Return a formatted string describing the current GPT model."
  (format "Model: (%s)"
          (propertize (substring-no-properties
                       elfai-model)
                      'face
                      'transient-value)))

;;;###autoload (autoload 'elfai-menu "elfai" nil t)
(transient-define-prefix elfai-menu ()
  "Provide a menu for various AI-powered text and image processing functions."
  :refresh-suffixes t
  [["Actions"
    ("r" "Start session" elfai)
    ("h" "Complete at point (send all buffer)" elfai-complete-here
     :inapt-if-non-nil buffer-read-only)
    ("." "Complete (send region before point)"
     elfai-complete-with-partial-context
     :inapt-if-non-nil buffer-read-only)
    ("a" "Ask and insert"
     elfai-ask-and-insert :inapt-if-non-nil buffer-read-only)
    ("g" "Generate images" elfai-generate-images-batch)
    ""
    ("b" "change buffer" elfai-switch-to-buffer)]
   ["Settings"
    ("m" elfai-change-default-model
     :description elfai-model-description)
    ("i" "Inspect request data" elfai-inspect-request-data)
    ("I" "Inspect request data as json" (lambda ()
                                          (interactive)
                                          (let ((current-prefix-arg '(4)))
                                            (call-interactively
                                             #'elfai-inspect-request-data))))
    ("<up>" elfai-increase-temperature)
    ("<down>" elfai-decrease-temperature)]]
  [[:description (lambda ()
                   (let ((prompt (car (split-string
                                       (or (elfai-system-prompt) "")
                                       "[\n\r\f]+" t))))
                     (if prompt
                         (format "System prompt\n\s%s"
                                 (truncate-string-to-width prompt 45 nil nil t))
                       "System prompt\n")))
    ("p" elfai-prev-system-prompt)
    ("n" elfai-next-system-prompt)
    ("+" elfai-add-system-prompt)
    ("-" elfai-delete-system-prompt)
    ("e" elfai-edit-system-prompt)
    ("<" "Edit the response formatting"  elfai-edit-response-wrap)
    ("C-x C-w" "Save prompts"
     (lambda ()
       (interactive)
       (customize-save-variable 'elfai-system-prompt-alist
                                elfai-system-prompt-alist))
     :transient t)]])


(provide 'elfai)
;;; elfai.el ends here