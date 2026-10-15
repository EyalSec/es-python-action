# Example

`tests/test_greeting.py` is a deliberately vulnerable test used by this
repository's end-to-end workflow. It receives a name over a network connection
and joins it into a shell command, so a name containing `;` runs a second
command. Under es-python with the **socket** source on, that flow is reported.

Do not copy `greet()` into real code. The fix is to pass a list of arguments
and no shell: `subprocess.run(["echo", "hello", name])`.
