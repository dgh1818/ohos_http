import StandardMessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/StandardMessageCodec';
import BasicMessageChannel, { Reply } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BasicMessageChannel';
import { BinaryMessenger,TaskQueue } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import MessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/MessageCodec';
import { ByteBuffer } from '@ohos/flutter_ohos/src/main/ets/util/ByteBuffer';

// Manual post-generation fix: the OHOS pigeon fork still emits number[] for
// byte arrays here. Keep these bridge payloads as Uint8Array until upstream is fixed.


/** Error class for passing custom error details to Flutter via a thrown PlatformException. */
export class FlutterError implements Error {

  /** The error code. */
  public code: string;

  /** The error name. */
  public name: string;

  /** The error message. */
  public message: string;
  /** The error stack. */
  public stack?: string;

  constructor(code: string, name: string,  message: string, stack?: string) 
  {
    this.code = code;
    this.name = name;
    this.message = message;
    this.stack = stack;
  }
}

function wrapError(error: Error): Array<Object> {
  let errorList: Array<Object> = new Array<Object>(3);
  if (error instanceof FlutterError) {
    let err: FlutterError = error as FlutterError;
    errorList[0] = err.code;
    errorList[1] = err.name;
    errorList[2] = err.message;
  } else {
    errorList[0] = error.toString();
    errorList[1] = error.name;
    errorList[2] = "Cause: " + error.message + ", Stacktrace: " + error.stack;
  }
  return errorList;
}


/* Generated class from Pigeon that represents data sent in messages.*/
export class NativeHttpRequestOhos {
  private method?: string;

  public setMethod(method:string):void {
    this.method = method;
  }

  getMethod(): string | undefined{
    return this.method;
  }

  private url?: string;

  public setUrl(url:string):void {
    this.url = url;
  }

  getUrl(): string | undefined{
    return this.url;
  }

  private headers?: Map<string, string>;

  public setHeaders(headers:Map<string, string>):void {
    this.headers = headers;
  }

  getHeaders(): Map<string, string> | undefined{
    return this.headers;
  }

  private body?: Uint8Array;

  public setBody(body:Uint8Array):void {
    this.body = body;
  }

  getBody(): Uint8Array | undefined{
    return this.body;
  }

  private connectTimeoutMs?: number;

  public setConnectTimeoutMs(connectTimeoutMs:number):void {
    this.connectTimeoutMs = connectTimeoutMs;
  }

  getConnectTimeoutMs(): number | undefined{
    return this.connectTimeoutMs;
  }

  private readTimeoutMs?: number;

  public setReadTimeoutMs(readTimeoutMs:number):void {
    this.readTimeoutMs = readTimeoutMs;
  }

  getReadTimeoutMs(): number | undefined{
    return this.readTimeoutMs;
  }

  constructor(method?: string, url?: string, headers?: Map<string, string>, body?: Uint8Array, connectTimeoutMs?: number, readTimeoutMs?: number) {
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.body = body;
    this.connectTimeoutMs = connectTimeoutMs;
    this.readTimeoutMs = readTimeoutMs;
  }

  toList(): Object[] {
    let arr: Object[] = new Array();
    if(this.method !==undefined){
      arr.push(this.method);
    }
    if(this.url !==undefined){
      arr.push(this.url);
    }
    if(this.headers !==undefined){
      arr.push(this.headers);
    }
    if(this.body !==undefined){
      arr.push(this.body);
    }
    if(this.connectTimeoutMs !==undefined){
      arr.push(this.connectTimeoutMs);
    }
    if(this.readTimeoutMs !==undefined){
      arr.push(this.readTimeoutMs);
    }
    return arr;
  }

  static fromList(arr: Object[]): NativeHttpRequestOhos {
    let pigeonResult: NativeHttpRequestOhos = new NativeHttpRequestOhos();
    let method: Object = arr[0];
    pigeonResult.setMethod(method as string);
    let url: Object = arr[1];
    pigeonResult.setUrl(url as string);
    let headers: Object = arr[2];
    pigeonResult.setHeaders(headers as Map<string, string>);
    let body: Object = arr[3];
    pigeonResult.setBody(body as Uint8Array);
    let connectTimeoutMs: Object = arr[4];
    pigeonResult.setConnectTimeoutMs(connectTimeoutMs as number);
    let readTimeoutMs: Object = arr[5];
    pigeonResult.setReadTimeoutMs(readTimeoutMs as number);
    return pigeonResult;
  }
}

/* Generated class from Pigeon that represents data sent in messages.*/
export class NativeHttpResponseOhos {
  private statusCode?: number;

  public setStatusCode(statusCode:number):void {
    this.statusCode = statusCode;
  }

  getStatusCode(): number | undefined{
    return this.statusCode;
  }

  private headers?: Map<string, string>;

  public setHeaders(headers:Map<string, string>):void {
    this.headers = headers;
  }

  getHeaders(): Map<string, string> | undefined{
    return this.headers;
  }

  private body?: Uint8Array;

  public setBody(body:Uint8Array):void {
    this.body = body;
  }

  getBody(): Uint8Array | undefined{
    return this.body;
  }

  constructor(statusCode?: number, headers?: Map<string, string>, body?: Uint8Array) {
    this.statusCode = statusCode;
    this.headers = headers;
    this.body = body;
  }

  toList(): Object[] {
    let arr: Object[] = new Array();
    if(this.statusCode !==undefined){
      arr.push(this.statusCode);
    }
    if(this.headers !==undefined){
      arr.push(this.headers);
    }
    if(this.body !==undefined){
      arr.push(this.body);
    }
    return arr;
  }

  static fromList(arr: Object[]): NativeHttpResponseOhos {
    let pigeonResult: NativeHttpResponseOhos = new NativeHttpResponseOhos();
    let statusCode: Object = arr[0];
    pigeonResult.setStatusCode(statusCode as number);
    let headers: Object = arr[1];
    pigeonResult.setHeaders(headers as Map<string, string>);
    let body: Object = arr[2];
    pigeonResult.setBody(body as Uint8Array);
    return pigeonResult;
  }
}

/* Generated class from Pigeon that represents data sent in messages.*/
export class NativeHttpStreamHeadersOhos {
  private statusCode?: number;

  public setStatusCode(statusCode:number):void {
    this.statusCode = statusCode;
  }

  getStatusCode(): number | undefined{
    return this.statusCode;
  }

  private headers?: Map<string, string>;

  public setHeaders(headers:Map<string, string>):void {
    this.headers = headers;
  }

  getHeaders(): Map<string, string> | undefined{
    return this.headers;
  }

  constructor(statusCode?: number, headers?: Map<string, string>) {
    this.statusCode = statusCode;
    this.headers = headers;
  }

  toList(): Object[] {
    let arr: Object[] = new Array();
    if(this.statusCode !==undefined){
      arr.push(this.statusCode);
    }
    if(this.headers !==undefined){
      arr.push(this.headers);
    }
    return arr;
  }

  static fromList(arr: Object[]): NativeHttpStreamHeadersOhos {
    let pigeonResult: NativeHttpStreamHeadersOhos = new NativeHttpStreamHeadersOhos();
    let statusCode: Object = arr[0];
    pigeonResult.setStatusCode(statusCode as number);
    let headers: Object = arr[1];
    pigeonResult.setHeaders(headers as Map<string, string>);
    return pigeonResult;
  }
}

/* Generated class from Pigeon that represents data sent in messages.*/
export class NativeHttpMultipartRequestOhos {
  private method?: string;

  public setMethod(method:string):void {
    this.method = method;
  }

  getMethod(): string | undefined{
    return this.method;
  }

  private url?: string;

  public setUrl(url:string):void {
    this.url = url;
  }

  getUrl(): string | undefined{
    return this.url;
  }

  private headers?: Map<string, string>;

  public setHeaders(headers:Map<string, string>):void {
    this.headers = headers;
  }

  getHeaders(): Map<string, string> | undefined{
    return this.headers;
  }

  private fields?: Map<string, string>;

  public setFields(fields:Map<string, string>):void {
    this.fields = fields;
  }

  getFields(): Map<string, string> | undefined{
    return this.fields;
  }

  private fileFieldName?: string;

  public setFileFieldName(fileFieldName:string):void {
    this.fileFieldName = fileFieldName;
  }

  getFileFieldName(): string | undefined{
    return this.fileFieldName;
  }

  private filePath?: string;

  public setFilePath(filePath:string):void {
    this.filePath = filePath;
  }

  getFilePath(): string | undefined{
    return this.filePath;
  }

  private fileName?: string;

  public setFileName(fileName:string):void {
    this.fileName = fileName;
  }

  getFileName(): string | undefined{
    return this.fileName;
  }

  private contentType?: string;

  public setContentType(contentType:string):void {
    this.contentType = contentType;
  }

  getContentType(): string | undefined{
    return this.contentType;
  }

  private connectTimeoutMs?: number;

  public setConnectTimeoutMs(connectTimeoutMs:number):void {
    this.connectTimeoutMs = connectTimeoutMs;
  }

  getConnectTimeoutMs(): number | undefined{
    return this.connectTimeoutMs;
  }

  private readTimeoutMs?: number;

  public setReadTimeoutMs(readTimeoutMs:number):void {
    this.readTimeoutMs = readTimeoutMs;
  }

  getReadTimeoutMs(): number | undefined{
    return this.readTimeoutMs;
  }

  constructor(method?: string, url?: string, headers?: Map<string, string>, fields?: Map<string, string>, fileFieldName?: string, filePath?: string, fileName?: string, contentType?: string, connectTimeoutMs?: number, readTimeoutMs?: number) {
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.fields = fields;
    this.fileFieldName = fileFieldName;
    this.filePath = filePath;
    this.fileName = fileName;
    this.contentType = contentType;
    this.connectTimeoutMs = connectTimeoutMs;
    this.readTimeoutMs = readTimeoutMs;
  }

  toList(): Object[] {
    let arr: Object[] = new Array();
    if(this.method !==undefined){
      arr.push(this.method);
    }
    if(this.url !==undefined){
      arr.push(this.url);
    }
    if(this.headers !==undefined){
      arr.push(this.headers);
    }
    if(this.fields !==undefined){
      arr.push(this.fields);
    }
    if(this.fileFieldName !==undefined){
      arr.push(this.fileFieldName);
    }
    if(this.filePath !==undefined){
      arr.push(this.filePath);
    }
    if(this.fileName !==undefined){
      arr.push(this.fileName);
    }
    if(this.contentType !==undefined){
      arr.push(this.contentType);
    }
    if(this.connectTimeoutMs !==undefined){
      arr.push(this.connectTimeoutMs);
    }
    if(this.readTimeoutMs !==undefined){
      arr.push(this.readTimeoutMs);
    }
    return arr;
  }

  static fromList(arr: Object[]): NativeHttpMultipartRequestOhos {
    let pigeonResult: NativeHttpMultipartRequestOhos = new NativeHttpMultipartRequestOhos();
    let method: Object = arr[0];
    pigeonResult.setMethod(method as string);
    let url: Object = arr[1];
    pigeonResult.setUrl(url as string);
    let headers: Object = arr[2];
    pigeonResult.setHeaders(headers as Map<string, string>);
    let fields: Object = arr[3];
    pigeonResult.setFields(fields as Map<string, string>);
    let fileFieldName: Object = arr[4];
    pigeonResult.setFileFieldName(fileFieldName as string);
    let filePath: Object = arr[5];
    pigeonResult.setFilePath(filePath as string);
    let fileName: Object = arr[6];
    pigeonResult.setFileName(fileName as string);
    let contentType: Object = arr[7];
    pigeonResult.setContentType(contentType as string);
    let connectTimeoutMs: Object = arr[8];
    pigeonResult.setConnectTimeoutMs(connectTimeoutMs as number);
    let readTimeoutMs: Object = arr[9];
    pigeonResult.setReadTimeoutMs(readTimeoutMs as number);
    return pigeonResult;
  }
}

export class PigeonCodec extends StandardMessageCodec {
  static readonly INSTANCE: PigeonCodec  = new PigeonCodec();

  getByte(n: number): number {
    let byteArray = new Uint8Array(1);
    byteArray[0] = n;
    return byteArray[0] as number;
  }
  private constructor() {
    super();
  }

  readValueOfType(type: number,  buffer: ByteBuffer): ESObject {
    switch (type) {
      case this.getByte(129):
        return NativeHttpRequestOhos.fromList(super.readValue(buffer) as Object[]);
      case this.getByte(130):
        return NativeHttpResponseOhos.fromList(super.readValue(buffer) as Object[]);
      case this.getByte(131):
        return NativeHttpStreamHeadersOhos.fromList(super.readValue(buffer) as Object[]);
      case this.getByte(132):
        return NativeHttpMultipartRequestOhos.fromList(super.readValue(buffer) as Object[]);
      default:
        return super.readValueOfType(type, buffer);
    }
  }

  writeValue(stream: ByteBuffer , value: ESObject): ESObject{
    if (value instanceof NativeHttpRequestOhos) {
      stream.writeUint8(this.getByte(129));
      this.writeValue(stream, (value as NativeHttpRequestOhos).toList());
    } else if (value instanceof NativeHttpResponseOhos) {
      stream.writeUint8(this.getByte(130));
      this.writeValue(stream, (value as NativeHttpResponseOhos).toList());
    } else if (value instanceof NativeHttpStreamHeadersOhos) {
      stream.writeUint8(this.getByte(131));
      this.writeValue(stream, (value as NativeHttpStreamHeadersOhos).toList());
    } else if (value instanceof NativeHttpMultipartRequestOhos) {
      stream.writeUint8(this.getByte(132));
      this.writeValue(stream, (value as NativeHttpMultipartRequestOhos).toList());
    } else {
      super.writeValue(stream, value);
    }
  }
}


export interface Result<T> {
  success( result: T ): void;

  error( error: Error): void;
}
/* Generated abstract class from Pigeon that represents a handler of messages from Flutter.*/
export abstract class NativeHttpApiOhos {

  abstract sendRequest(request: NativeHttpRequestOhos , result: Result<NativeHttpResponseOhos>): void;

  abstract sendStreamRequest(requestId: number , request: NativeHttpRequestOhos , result: Result<void>): void;

  abstract cancelStreamRequest(requestId: number ): void;

  abstract sendMultipartRequest(requestId: number , request: NativeHttpMultipartRequestOhos , result: Result<NativeHttpResponseOhos>): void;

  abstract cancelMultipartRequest(requestId: number ): void;
  /** The codec used by NativeHttpApiOhos. */
  static getCodec(): MessageCodec<Object>{
    return PigeonCodec.INSTANCE;
  }
  /*Sets up an instance of `NativeHttpApiOhos` to handle messages through the `binaryMessenger`.*/
  static setup(binaryMessenger: BinaryMessenger, api: NativeHttpApiOhos | null): void {
    {
      let channel: BasicMessageChannel<Object> =
          new BasicMessageChannel(
              binaryMessenger, "dev.flutter.pigeon.ohos_http.NativeHttpApiOhos.sendRequest", NativeHttpApiOhos.getCodec());
      if (api != null) {
        channel.setMessageHandler({
            onMessage(message: Object ,reply: Reply<Object> ) {
              let args: Array<Object> = message as Array<Object>;
              class ResultImp implements Result<NativeHttpResponseOhos>{
                    success(result: NativeHttpResponseOhos): void {
                      let res: Array<Object> = [];
                      res.push(result);
                      reply.reply(res);
                    }

                    error(error: Error): void {
                      let wrappedError: Array<Object> = wrapError(error);
                      reply.reply(wrappedError);
                    }
              }
              let resultCallback: Result<NativeHttpResponseOhos> = new ResultImp();

              api!.sendRequest(args[0] as NativeHttpRequestOhos, resultCallback);
            } });
      } else {
        channel.setMessageHandler(null);
      }
    }
    {
      let channel: BasicMessageChannel<Object> =
          new BasicMessageChannel(
              binaryMessenger, "dev.flutter.pigeon.ohos_http.NativeHttpApiOhos.sendStreamRequest", NativeHttpApiOhos.getCodec());
      if (api != null) {
        channel.setMessageHandler({
            onMessage(message: Object ,reply: Reply<Object> ) {
              let args: Array<Object> = message as Array<Object>;
              class ResultImp implements Result<void>{
                    success(result: void): void {
                      let res: Array<Object> = [];
                      res.push(null);
                      reply.reply(res);
                    }

                    error(error: Error): void {
                      let wrappedError: Array<Object> = wrapError(error);
                      reply.reply(wrappedError);
                    }
              }
              let resultCallback: Result<void> = new ResultImp();

              api!.sendStreamRequest(args[0] as number, args[1] as NativeHttpRequestOhos, resultCallback);
            } });
      } else {
        channel.setMessageHandler(null);
      }
    }
    {
      let channel: BasicMessageChannel<Object> =
          new BasicMessageChannel(
              binaryMessenger, "dev.flutter.pigeon.ohos_http.NativeHttpApiOhos.cancelStreamRequest", NativeHttpApiOhos.getCodec());
      if (api != null) {
        channel.setMessageHandler({
            onMessage(message: Object ,reply: Reply<Object> ) {
              let args: Array<Object> = message as Array<Object>;
              let res: Array<Object> = [];
              try {
                api!.cancelStreamRequest(args[0] as number);
                res.push(null);
              }
 catch (error) {
                let wrappedError: Array<Object> = wrapError(error);
                res = wrappedError;
              }
              reply.reply(res);
            } });
      } else {
        channel.setMessageHandler(null);
      }
    }
    {
      let channel: BasicMessageChannel<Object> =
          new BasicMessageChannel(
              binaryMessenger, "dev.flutter.pigeon.ohos_http.NativeHttpApiOhos.sendMultipartRequest", NativeHttpApiOhos.getCodec());
      if (api != null) {
        channel.setMessageHandler({
            onMessage(message: Object ,reply: Reply<Object> ) {
              let args: Array<Object> = message as Array<Object>;
              class ResultImp implements Result<NativeHttpResponseOhos>{
                    success(result: NativeHttpResponseOhos): void {
                      let res: Array<Object> = [];
                      res.push(result);
                      reply.reply(res);
                    }

                    error(error: Error): void {
                      let wrappedError: Array<Object> = wrapError(error);
                      reply.reply(wrappedError);
                    }
              }
              let resultCallback: Result<NativeHttpResponseOhos> = new ResultImp();

              api!.sendMultipartRequest(args[0] as number, args[1] as NativeHttpMultipartRequestOhos, resultCallback);
            } });
      } else {
        channel.setMessageHandler(null);
      }
    }
    {
      let channel: BasicMessageChannel<Object> =
          new BasicMessageChannel(
              binaryMessenger, "dev.flutter.pigeon.ohos_http.NativeHttpApiOhos.cancelMultipartRequest", NativeHttpApiOhos.getCodec());
      if (api != null) {
        channel.setMessageHandler({
            onMessage(message: Object ,reply: Reply<Object> ) {
              let args: Array<Object> = message as Array<Object>;
              let res: Array<Object> = [];
              try {
                api!.cancelMultipartRequest(args[0] as number);
                res.push(null);
              }
 catch (error) {
                let wrappedError: Array<Object> = wrapError(error);
                res = wrappedError;
              }
              reply.reply(res);
            } });
      } else {
        channel.setMessageHandler(null);
      }
    }
  }
}
/* Generated class from Pigeon that represents Flutter messages that can be called from ArkTS.*/
export class NativeHttpFlutterApiOhos {
  binaryMessenger: BinaryMessenger;

  constructor(binaryMessenger: BinaryMessenger) {
    this.binaryMessenger = binaryMessenger;
  }

  /** The codec used by NativeHttpFlutterApiOhos. */
  static getCodec(): MessageCodec<Object> {
    return PigeonCodec.INSTANCE;
  }

  onStreamHeaders(requestIdArg: number,responseArg: NativeHttpStreamHeadersOhos, callback: Reply<void>) {
    const channelName: string = 'dev.flutter.pigeon.ohos_http.NativeHttpFlutterApiOhos.onStreamHeaders';
    let channel: BasicMessageChannel<Object> = 
        new BasicMessageChannel<Object>(
            this.binaryMessenger, channelName, NativeHttpFlutterApiOhos.getCodec());
    channel.send(
        [requestIdArg, responseArg],
        channelReply => {
          if (Array.isArray(channelReply)) {
            let listReply: ESObject[] = channelReply as ESObject[] ;
            if (listReply.length > 1) {
              let arrFirst:string = listReply[0] as string;
              let arrSecond:string = listReply[1] as string;
              let arrThird:string = listReply[2] as string;
              let replyArr:ESObject = new FlutterError(arrFirst, arrSecond, arrThird)
              callback.reply(replyArr);
            } else {
              callback.reply();
            }
          }  else {
            let connErr:ESObject = new FlutterError('channel-error', "Unable to establish connection on channel: " + channelName + ".", "")
            callback.reply(connErr);
          } 
        });
  }
  onStreamData(requestIdArg: number,chunkArg: Uint8Array, callback: Reply<void>) {
    const channelName: string = 'dev.flutter.pigeon.ohos_http.NativeHttpFlutterApiOhos.onStreamData';
    let channel: BasicMessageChannel<Object> = 
        new BasicMessageChannel<Object>(
            this.binaryMessenger, channelName, NativeHttpFlutterApiOhos.getCodec());
    channel.send(
        [requestIdArg, chunkArg],
        channelReply => {
          if (Array.isArray(channelReply)) {
            let listReply: ESObject[] = channelReply as ESObject[] ;
            if (listReply.length > 1) {
              let arrFirst:string = listReply[0] as string;
              let arrSecond:string = listReply[1] as string;
              let arrThird:string = listReply[2] as string;
              let replyArr:ESObject = new FlutterError(arrFirst, arrSecond, arrThird)
              callback.reply(replyArr);
            } else {
              callback.reply();
            }
          }  else {
            let connErr:ESObject = new FlutterError('channel-error', "Unable to establish connection on channel: " + channelName + ".", "")
            callback.reply(connErr);
          } 
        });
  }
  onStreamComplete(requestIdArg: number,statusCodeArg: number, callback: Reply<void>) {
    const channelName: string = 'dev.flutter.pigeon.ohos_http.NativeHttpFlutterApiOhos.onStreamComplete';
    let channel: BasicMessageChannel<Object> = 
        new BasicMessageChannel<Object>(
            this.binaryMessenger, channelName, NativeHttpFlutterApiOhos.getCodec());
    channel.send(
        [requestIdArg, statusCodeArg],
        channelReply => {
          if (Array.isArray(channelReply)) {
            let listReply: ESObject[] = channelReply as ESObject[] ;
            if (listReply.length > 1) {
              let arrFirst:string = listReply[0] as string;
              let arrSecond:string = listReply[1] as string;
              let arrThird:string = listReply[2] as string;
              let replyArr:ESObject = new FlutterError(arrFirst, arrSecond, arrThird)
              callback.reply(replyArr);
            } else {
              callback.reply();
            }
          }  else {
            let connErr:ESObject = new FlutterError('channel-error', "Unable to establish connection on channel: " + channelName + ".", "")
            callback.reply(connErr);
          } 
        });
  }
  onStreamError(requestIdArg: number,codeArg: string,messageArg: string, callback: Reply<void>) {
    const channelName: string = 'dev.flutter.pigeon.ohos_http.NativeHttpFlutterApiOhos.onStreamError';
    let channel: BasicMessageChannel<Object> = 
        new BasicMessageChannel<Object>(
            this.binaryMessenger, channelName, NativeHttpFlutterApiOhos.getCodec());
    channel.send(
        [requestIdArg, codeArg, messageArg],
        channelReply => {
          if (Array.isArray(channelReply)) {
            let listReply: ESObject[] = channelReply as ESObject[] ;
            if (listReply.length > 1) {
              let arrFirst:string = listReply[0] as string;
              let arrSecond:string = listReply[1] as string;
              let arrThird:string = listReply[2] as string;
              let replyArr:ESObject = new FlutterError(arrFirst, arrSecond, arrThird)
              callback.reply(replyArr);
            } else {
              callback.reply();
            }
          }  else {
            let connErr:ESObject = new FlutterError('channel-error', "Unable to establish connection on channel: " + channelName + ".", "")
            callback.reply(connErr);
          } 
        });
  }
  onUploadProgress(requestIdArg: number,bytesSentArg: number,totalBytesArg: number, callback: Reply<void>) {
    const channelName: string = 'dev.flutter.pigeon.ohos_http.NativeHttpFlutterApiOhos.onUploadProgress';
    let channel: BasicMessageChannel<Object> = 
        new BasicMessageChannel<Object>(
            this.binaryMessenger, channelName, NativeHttpFlutterApiOhos.getCodec());
    channel.send(
        [requestIdArg, bytesSentArg, totalBytesArg],
        channelReply => {
          if (Array.isArray(channelReply)) {
            let listReply: ESObject[] = channelReply as ESObject[] ;
            if (listReply.length > 1) {
              let arrFirst:string = listReply[0] as string;
              let arrSecond:string = listReply[1] as string;
              let arrThird:string = listReply[2] as string;
              let replyArr:ESObject = new FlutterError(arrFirst, arrSecond, arrThird)
              callback.reply(replyArr);
            } else {
              callback.reply();
            }
          }  else {
            let connErr:ESObject = new FlutterError('channel-error', "Unable to establish connection on channel: " + channelName + ".", "")
            callback.reply(connErr);
          } 
        });
  }
}
