;; extends

; NixOS test scripts are Python regardless of the surrounding test helper.
(binding
  attrpath: (attrpath (identifier) @_name)
  expression: [
    (string_expression (string_fragment) @injection.content)
    (indented_string_expression (string_fragment) @injection.content)
    ; Tests can append a separate Python file to their inline setup.
    (binary_expression
      left: [
        (string_expression (string_fragment) @injection.content)
        (indented_string_expression (string_fragment) @injection.content)
      ]
      operator: "+")
  ]
  (#eq? @_name "testScript")
  (#set! injection.language "python"))
