import { sendableContextManager } from '@kit.AbilityKit';

@Sendable
export class NativeHttpRequestCommand {
  public requestId: number;
  public command: string;
  public sendableAppContext: sendableContextManager.SendableContext;
  public requestJson: string;

  constructor(
    requestId: number,
    command: string,
    sendableAppContext: sendableContextManager.SendableContext,
    requestJson: string,
  ) {
    this.requestId = requestId;
    this.command = command;
    this.sendableAppContext = sendableAppContext;
    this.requestJson = requestJson;
  }
}
