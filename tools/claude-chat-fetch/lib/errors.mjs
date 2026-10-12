export class ChatReaderError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.name = 'ChatReaderError';
    this.exitCode = exitCode;
  }
}
