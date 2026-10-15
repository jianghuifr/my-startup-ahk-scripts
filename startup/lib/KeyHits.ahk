; Count consecutive presses of the current hotkey's key within `timeout` seconds.
KeyHits(timeout := 0.2) {
    key := RegExReplace(A_ThisHotKey, "[\*\~\$\#\+\!\^( UP)]")
    Loop {
        KeyWait(key)
        if !KeyWait(key, "D T" timeout) ; timed out waiting for the next press
            return A_Index
    }
}
