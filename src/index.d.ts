// Type definitions for @kesha-antonov/react-native-background-downloader 2.6
// Project: https://github.com/kesha-antonov/react-native-background-downloader
// Definitions by: Philip Su <https://github.com/fivecar>,
//                 Adam Hunter <https://github.com/adamrhunter>,
//                 Junseong Park <https://github.com/Kweiza>
// Definitions: https://github.com/DefinitelyTyped/DefinitelyTyped

export interface DownloadHeaders {
  [key: string]: string | null
}

export interface Config {
  headers: DownloadHeaders
  progressInterval: number
  isLogsEnabled: boolean
}

type SetConfig = (config: Partial<Config>) => void

export interface BeginHandlerObject {
  expectedBytes: number
  headers: { [key: string]: string }
}
export type BeginHandler = ({
  expectedBytes,
  headers,
}: BeginHandlerObject) => void

export interface ProgressHandlerObject {
  bytes: number
  bytesTotal: number
}
export type ProgressHandler = ({
  bytes,
  bytesTotal,
}: ProgressHandlerObject) => void

export interface DoneHandlerObject {
  bytes: number
  bytesTotal: number
}
export type DoneHandler = ({
  bytes,
  bytesTotal,
}: DoneHandlerObject) => void

export interface ErrorHandlerObject {
  error: string
  errorCode: number
}
export type ErrorHandler = ({
  error,
  errorCode,
}: ErrorHandlerObject) => void

export interface TaskInfoObject {
  id: string
  type: 0 | 1 // 0 - Download, 1 - Upload
  metadata: object | string

  bytes?: number
  bytesTotal?: number

  beginHandler?: BeginHandler
  progressHandler?: ProgressHandler
  doneHandler?: DoneHandler
  errorHandler?: ErrorHandler
}
export type TaskInfo = TaskInfoObject

export type SessionTaskType =
  | 0 // Download
  | 1 // Upload

export type SessionTaskState =
  | 'PENDING'
  | 'PROCESSING'
  | 'PAUSED'
  | 'DONE'
  | 'FAILED'
  | 'STOPPED'

export interface SessionTask {
  constructor: (taskInfo: TaskInfo) => SessionTask

  id: string
  type: SessionTaskType
  state: SessionTaskState
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  metadata: Record<string, any>
  bytes: number
  bytesTotal: number

  begin: (handler: BeginHandler) => SessionTask
  progress: (handler: ProgressHandler) => SessionTask
  done: (handler: DoneHandler) => SessionTask
  error: (handler: ErrorHandler) => SessionTask

  _beginHandler: BeginHandler
  _progressHandler: ProgressHandler
  _doneHandler: DoneHandler
  _errorHandler: ErrorHandler

  pause: () => void
  resume: () => void
  stop: () => void
}

export type CheckForExistingDownloads = () => Promise<SessionTask[]>
export type EnsureDownloadsAreRunning = () => Promise<void>

export interface DownloadOptions {
  id: string
  url: string
  destination: string
  headers?: DownloadHeaders | undefined
  metadata?: object
  isAllowedOverRoaming?: boolean
  isAllowedOverMetered?: boolean
  isNotificationVisible?: boolean
  notificationTitle?: string
}

export interface UploadOptions {
  id: string
  url: string
  source: string
  headers?: DownloadHeaders | undefined
  metadata?: object
  isAllowedOverRoaming?: boolean
  isAllowedOverMetered?: boolean
  isNotificationVisible?: boolean
  notificationTitle?: string
}

export type Download = (options: DownloadOptions) => SessionTask
export type Upload = (options: UploadOptions) => SessionTask
export type CompleteHandler = (id: string) => void

export interface Directories {
  documents: string
}

export const setConfig: SetConfig
export const checkForExistingDownloads: CheckForExistingDownloads
export const ensureDownloadsAreRunning: EnsureDownloadsAreRunning
export const download: Download
export const upload: Upload
export const completeHandler: CompleteHandler
export const directories: Directories

export interface RNBackgroundDownloader {
  setConfig: SetConfig
  checkForExistingDownloads: CheckForExistingDownloads
  ensureDownloadsAreRunning: EnsureDownloadsAreRunning
  download: Download
  upload: Upload
  completeHandler: CompleteHandler
  directories: Directories
}

declare const RNBackgroundDownloader: RNBackgroundDownloader
export default RNBackgroundDownloader
