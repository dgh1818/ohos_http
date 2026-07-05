import { sendableContextManager } from '@kit.AbilityKit';

@Sendable
export class NativeMultipartUploadCommand {
  public requestId: number;
  public sendableAppContext: sendableContextManager.SendableContext;
  public requestJson: string;

  constructor(
    requestId: number,
    sendableAppContext: sendableContextManager.SendableContext,
    requestJson: string,
  ) {
    this.requestId = requestId;
    this.sendableAppContext = sendableAppContext;
    this.requestJson = requestJson;
  }
}
