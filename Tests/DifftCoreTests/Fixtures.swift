enum Fixtures {
    static let simpleModify = """
    diff --git a/src/app.py b/src/app.py
    index 1111111..2222222 100644
    --- a/src/app.py
    +++ b/src/app.py
    @@ -1,4 +1,4 @@ def main
     import os
    -DEBUG = False
    +DEBUG = True
     print(os.name)
    """

    static let addedFile = """
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    """

    static let deletedFile = """
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 4444444..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -bye
    """

    static let binaryFile = """
    diff --git a/logo.png b/logo.png
    index 5555555..6666666 100644
    Binary files a/logo.png and b/logo.png differ
    """

    static let renamedFile = """
    diff --git a/old_name.swift b/new_name.swift
    similarity index 90%
    rename from old_name.swift
    rename to new_name.swift
    index 7777777..8888888 100644
    --- a/old_name.swift
    +++ b/new_name.swift
    @@ -3,3 +3,3 @@
     let a = 1
    -let b = 2
    +let b = 3
     let c = 4
    """

    static let multiHunk = """
    diff --git a/m.txt b/m.txt
    index aaaaaaa..bbbbbbb 100644
    --- a/m.txt
    +++ b/m.txt
    @@ -1,3 +1,3 @@
     one
    -two
    +TWO
     three
    @@ -10,3 +10,4 @@
     ten
     eleven
    +eleven.five
     twelve
    """
}
