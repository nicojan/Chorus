import ChorusEngine
import SwiftData

extension ModelContext {
    /// Saves, or logs the failure and rolls the context back. Returns whether
    /// the save landed.
    ///
    /// Without the rollback a failed change stays pending in the context and
    /// rides along on the next unrelated save that succeeds — a setting the user
    /// saw fail turns up later on its own.
    ///
    /// For saves that edit properties. The sheets that insert models keep
    /// logging and going on: rolling back a join row already wired to a live
    /// `Space` can leave a dangling link, the class of fault that crashes
    /// macOS 14, and an insert that rides along on a later save is the lesser
    /// harm.
    @discardableResult
    func saveOrRollBack(_ context: String) -> Bool {
        do {
            try save()
            return true
        } catch {
            AppLogger.dataStore.error("Failed to save (\(context)): \(error.localizedDescription)")
            rollback()
            return false
        }
    }
}
