/// Status of individual tasks in multi-task operations
///
/// Represents the lifecycle states of tasks in multi-spinner
/// operations, from initial creation to final completion.
enum TaskStatus {
  /// Task has been created but not yet started
  ///
  /// Initial state when a task is added to the multi-spinner
  /// but execution hasn't begun. Task is queued for processing.
  ///
  /// Visual indicator: Usually not displayed or shown as queued
  pending,

  /// Task is currently being executed
  ///
  /// Active state when the task is in progress. Shows animated
  /// spinner indicator to represent ongoing work.
  ///
  /// Visual indicator: Animated spinner symbol with task message
  running,

  /// Task has finished successfully
  ///
  /// Final state indicating successful completion of the task.
  /// No further processing will occur for this task.
  ///
  /// Visual indicator: Success icon (✓) with completion message
  completed,

  /// Task has encountered an error and failed
  ///
  /// Final state indicating the task could not be completed
  /// due to an error or exception during execution.
  ///
  /// Visual indicator: Error icon (✗) with failure message
  failed,
}
