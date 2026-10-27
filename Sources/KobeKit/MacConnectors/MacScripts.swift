import Foundation

/// The AppleScript sources Kobe App sends to Mail and Notes. Each returns one text value: fields joined by ASCII 31,
/// each record ended by ASCII 30, with both characters and line breaks replaced inside every field first. Dates go
/// out as whole seconds relative to now, so no locale's date format is ever parsed.
public enum MacScripts {
    /// The helpers every read script starts with.
    static let helpers = """
    on swap(t, f, r)
    	set AppleScript's text item delimiters to f
    	set parts to text items of t
    	set AppleScript's text item delimiters to r
    	set t to parts as text
    	set AppleScript's text item delimiters to ""
    	return t
    end swap

    on clean(t)
    	if t is missing value then return ""
    	set t to t as text
    	repeat with f in {character id 30, character id 31, return, linefeed}
    		set t to my swap(t, f as text, " ")
    	end repeat
    	return t
    end clean

    on head(t, n)
    	if t is missing value then return ""
    	set t to t as text
    	if (length of t) > n then set t to text 1 thru n of t
    	return t
    end head

    """

    /// Rethrown inside a record's `try`: the app quit or Kobe was refused; any other error skips that record.
    static let fatal = "if errNum is -600 or errNum is -1743 or errNum is -1744 then error number errNum"

    /// Never launches the app (`is running` doesn't): a quit between Kobe's check and the read ends as -600.
    static func running(_ bundleID: String) -> String {
        "if not (application id \"\(bundleID)\" is running) then error number -600\n"
    }

    /// A header record ("#unread", the inbox's whole unread count), then up to 30 messages of the last 14 days of
    /// the unified inbox, unread first, newest first, picked by date here. Fields: message id, sender, subject,
    /// seconds since now (negative), read status ("true"/"false"), account name, the first 200 characters.
    public static let mail = helpers + running("com.apple.mail") + """
    set RS to character id 30
    set US to character id 31
    set nowDate to current date
    set cutoff to nowDate - 14 * days
    tell application "Mail"
    	set total to unread count of inbox
    	set picks to (messages of inbox whose date received > cutoff)
    	set recvDates to date received of (messages of inbox whose date received > cutoff)
    	set readFlags to read status of (messages of inbox whose date received > cutoff)
    end tell
    set out to "#unread" & US & total & RS
    set n to count of picks
    if (count of recvDates) is not n or (count of readFlags) is not n then return out
    -- Unread first, then by date: pick the best one left, 30 times.
    set taken to {}
    repeat 30 times
    	set best to 0
    	repeat with i from 1 to n
    		if taken does not contain i then
    			if best is 0 then
    				set best to i
    			else if ((item i of readFlags) is false and (item best of readFlags) is true) then
    				set best to i
    			else if (item i of readFlags) is (item best of readFlags) and (item i of recvDates) > (item best of recvDates) then
    				set best to i
    			end if
    		end if
    	end repeat
    	if best is 0 then exit repeat
    	set end of taken to best
    	try
    		set m to item best of picks
    		tell application "Mail"
    			set mid to message id of m
    			set who to sender of m
    			set subj to subject of m
    			set isRead to read status of m
    			set acct to name of account of mailbox of m
    			set preview to my head(content of m, 200)
    		end tell
    		set secs to ((item best of recvDates) - nowDate) as integer
    		set out to out & my clean(mid) & US & my clean(who) & US & my clean(subj) & US & secs & US & isRead & US & my clean(acct) & US & my clean(preview) & RS
    	on error number errNum
    		\(fatal)
    	end try
    end repeat
    return out
    """

    /// Notes' "Recently Deleted" folder, in the languages a Mac here is likely set to (it has no other mark).
    static let deletedFolders = ["Recently Deleted", "Eliminados recientemente", "Eliminado recientemente",
                                 "Suppressions récentes", "Supprimés récemment", "Zuletzt gelöscht",
                                 "Eliminati di recente", "Apagados recentemente", "Nylig slettet"]

    /// Every note outside Recently Deleted: id, name, folder name, seconds since its modification (negative). Read
    /// in bulk, three Apple Events per folder.
    public static let notesIndex = helpers + running("com.apple.Notes") + """
    set RS to character id 30
    set US to character id 31
    set nowDate to current date
    set deleted to {\(deletedFolders.map { "\"\($0)\"" }.joined(separator: ", "))}
    set out to ""
    tell application "Notes" to set allFolders to folders
    repeat with f in allFolders
    	try
    		tell application "Notes"
    			set folderName to name of f
    			set noteIDs to {}
    			if deleted does not contain folderName then
    				set noteIDs to id of notes of f
    				set noteNames to name of notes of f
    				set noteDates to modification date of notes of f
    			end if
    		end tell
    		repeat with i from 1 to count of noteIDs
    			try
    				set secs to ((item i of noteDates) - nowDate) as integer
    				set out to out & my clean(item i of noteIDs) & US & my clean(item i of noteNames) & US & my clean(folderName) & US & secs & RS
    			on error number errNum
    				\(fatal)
    			end try
    		end repeat
    	on error number errNum
    		\(fatal)
    	end try
    end repeat
    return out
    """

    /// For the given notes only: id, the first 400 characters of plain text (line breaks kept, the page shows three
    /// lines). A note that went away or can't be read (locked) is left out.
    public static func notesBody(ids: [String]) -> String {
        let list = ids.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        return helpers + running("com.apple.Notes") + """
        set RS to character id 30
        set US to character id 31
        set out to ""
        repeat with nid in {\(list)}
        	try
        		tell application "Notes" to set noteText to my head(plaintext of note id (nid as text), 400)
        		set noteText to my swap(noteText, character id 30, " ")
        		set noteText to my swap(noteText, character id 31, " ")
        		set out to out & my clean(nid) & US & noteText & RS
        	on error number errNum
        		\(fatal)
        	end try
        end repeat
        return out
        """
    }

    /// One note for the editor: seconds since its modification, locked, attachment count, the body HTML and its plain
    /// text (line breaks kept). A locked note's body isn't read.
    public static func noteRead(id: String) -> String {
        helpers + running("com.apple.Notes") + """
        set RS to character id 30
        set US to character id 31
        tell application "Notes"
        	set isLocked to password protected of note id "\(escape(id))"
        	set attachmentCount to count of attachments of note id "\(escape(id))"
        	set modDate to modification date of note id "\(escape(id))"
        	set noteHTML to ""
        	set noteText to ""
        	if not isLocked then
        		set noteHTML to body of note id "\(escape(id))"
        		set noteText to plaintext of note id "\(escape(id))"
        	end if
        end tell
        repeat with sep in {RS, US}
        	set noteHTML to my swap(noteHTML, sep as text, " ")
        	set noteText to my swap(noteText, sep as text, " ")
        end repeat
        set secs to (modDate - (current date)) as integer
        return (secs as text) & US & isLocked & US & attachmentCount & US & noteHTML & US & noteText & RS
        """
    }

    /// Saves the editor's body, only if the note is still as it was read (modified within 2 s of `modifiedEpoch`)
    /// and not locked; answers "#saved" with its new modification (seconds since now), "#changed" or "#locked".
    public static func noteWrite(id: String, html: String, modifiedEpoch: Int) -> String {
        running("com.apple.Notes") + """
        set RS to character id 30
        set US to character id 31
        set expectedEpoch to \(modifiedEpoch)
        set nowEpoch to (do shell script "date +%s") as number
        tell application "Notes"
        	set isLocked to password protected of note id "\(escape(id))"
        	set modDate to modification date of note id "\(escape(id))"
        end tell
        if isLocked then return "#locked" & RS
        set drift to nowEpoch + (modDate - (current date)) - expectedEpoch
        if drift > 2 or drift < -2 then return "#changed" & RS
        tell application "Notes"
        	set body of note id "\(escape(id))" to "\(escape(html))"
        	set savedDate to modification date of note id "\(escape(id))"
        end tell
        return "#saved" & US & ((savedDate - (current date)) as integer) & RS
        """
    }

    /// Opens one note in Notes. Only ever run on a click.
    public static func notesShow(id: String) -> String {
        """
        tell application "Notes"
        	show note id "\(escape(id))"
        	activate
        end tell
        """
    }

    /// For an AppleScript string literal.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
