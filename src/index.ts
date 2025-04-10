import { NativeModules, NativeEventEmitter } from 'react-native'
import SessionTask from './SessionTask'
import NativeRNBackgroundDownloader from './NativeRNBackgroundDownloader'
import { DownloadOptions, UploadOptions } from './index.d'

const { RNBackgroundDownloader } = NativeModules
const RNBackgroundDownloaderEmitter = new NativeEventEmitter(RNBackgroundDownloader)

const MIN_PROGRESS_INTERVAL = 250
const tasksMap = new Map()

const config = {
  headers: {},
  progressInterval: 1000,
  isLogsEnabled: false,
}

function log (...args) {
  if (config.isLogsEnabled)
    console.log('[RNBackgroundDownloader]', ...args)
}

RNBackgroundDownloaderEmitter.addListener('downloadBegin', ({ id, ...rest }) => {
  log('[RNBackgroundDownloader] downloadBegin', id, rest)
  const task = tasksMap.get(id)
  task?.onBegin(rest)
})

RNBackgroundDownloaderEmitter.addListener('uploadBegin', ({ id, ...rest }) => {
  log('[RNBackgroundDownloader] uploadBegin', id, rest)
  const task = tasksMap.get(id)
  task?.onBegin(rest)
})

RNBackgroundDownloaderEmitter.addListener('downloadProgress', events => {
  log('[RNBackgroundDownloader] downloadProgress-1', events, tasksMap)
  for (const event of events) {
    const { id, ...rest } = event
    const task = tasksMap.get(id)
    log('[RNBackgroundDownloader] downloadProgress-2', id, task)
    task?.onProgress(rest)
  }
})

RNBackgroundDownloaderEmitter.addListener('uploadProgress', events => {
  log('[RNBackgroundDownloader] uploadProgress-1', events, tasksMap)
  for (const event of events) {
    const { id, ...rest } = event
    const task = tasksMap.get(id)
    log('[RNBackgroundDownloader] uploadProgress-2', id, task)
    task?.onProgress(rest)
  }
})

RNBackgroundDownloaderEmitter.addListener('downloadComplete', ({ id, ...rest }) => {
  log('[RNBackgroundDownloader] downloadComplete', id, rest)
  const task = tasksMap.get(id)
  task?.onDone(rest)

  tasksMap.delete(id)
})

RNBackgroundDownloaderEmitter.addListener('uploadComplete', ({ id, ...rest }) => {
  log('[RNBackgroundDownloader] uploadComplete', id, rest)
  const task = tasksMap.get(id)
  task?.onDone(rest)

  tasksMap.delete(id)
})

RNBackgroundDownloaderEmitter.addListener('downloadFailed', ({ id, ...rest }) => {
  log('[RNBackgroundDownloader] downloadFailed', id, rest)
  const task = tasksMap.get(id)
  task?.onError(rest)

  tasksMap.delete(id)
})

RNBackgroundDownloaderEmitter.addListener('uploadFailed', ({ id, ...rest }) => {
  log('[RNBackgroundDownloader] uploadFailed', id, rest)
  const task = tasksMap.get(id)
  task?.onError(rest)

  tasksMap.delete(id)
})

export function setConfig ({ headers, progressInterval, isLogsEnabled }) {
  if (typeof headers === 'object') config.headers = headers

  if (progressInterval != null)
    if (typeof progressInterval === 'number' && progressInterval >= MIN_PROGRESS_INTERVAL)
      config.progressInterval = progressInterval
    else
      console.warn(`[RNBackgroundDownloader] progressInterval must be a number >= ${MIN_PROGRESS_INTERVAL}. You passed ${progressInterval}`)

  if (typeof isLogsEnabled === 'boolean') config.isLogsEnabled = isLogsEnabled
}

export async function checkForExistingDownloads () {
  log('[RNBackgroundDownloader] checkForExistingDownloads-1')
  const foundTasks = await NativeRNBackgroundDownloader.checkForExistingDownloads()
  log('[RNBackgroundDownloader] checkForExistingDownloads-2', foundTasks)

  return foundTasks.map(taskInfo => {
    // SECOND ARGUMENT RE-ASSIGNS EVENT HANDLERS
    const task = new SessionTask(taskInfo, tasksMap.get(taskInfo.id))
    log('[RNBackgroundDownloader] checkForExistingDownloads-3', taskInfo)

    if (taskInfo.state === RNBackgroundDownloader.TaskRunning) {
      task.state = 'PROCESSING'
    } else if (taskInfo.state === RNBackgroundDownloader.TaskSuspended) {
      task.state = 'PAUSED'
    } else if (taskInfo.state === RNBackgroundDownloader.TaskCanceling) {
      task.stop()
      return null
    } else if (taskInfo.state === RNBackgroundDownloader.TaskCompleted) {
      if (taskInfo.bytes === taskInfo.bytesTotal)
        task.state = 'DONE'
      else
        // IOS completed the download but it was not done.
        return null
    }
    tasksMap.set(taskInfo.id, task)
    return task
  }).filter(task => !!task)
}

export async function ensureDownloadsAreRunning () {
  log('[RNBackgroundDownloader] ensureDownloadsAreRunning')
  const tasks = await checkForExistingDownloads()
  for (const task of tasks)
    if (task.state === 'PROCESSING') {
      task.pause()
      task.resume()
    }
}

export function completeHandler (jobId: string) {
  if (jobId == null) {
    console.warn('[RNBackgroundDownloader] completeHandler: jobId is empty')
    return
  }

  return NativeRNBackgroundDownloader.completeHandler(jobId)
}

export function download (options: DownloadOptions) {
  log('[RNBackgroundDownloader] download', options)
  if (!options.id || !options.url || !options.destination)
    throw new Error('[RNBackgroundDownloader] id, url and destination are required')

  options.headers = { ...config.headers, ...options.headers }

  if (!(options.metadata && typeof options.metadata === 'object'))
    options.metadata = {}

  options.destination = options.destination.replace('file://', '')

  if (options.isAllowedOverRoaming == null) options.isAllowedOverRoaming = true
  if (options.isAllowedOverMetered == null) options.isAllowedOverMetered = true
  if (options.isNotificationVisible == null) options.isNotificationVisible = false

  const task = new SessionTask({
    id: options.id,
    type: 0, // Download
    metadata: options.metadata,
  })
  tasksMap.set(options.id, task)

  NativeRNBackgroundDownloader.download({
    ...options,
    metadata: JSON.stringify(options.metadata),
    progressInterval: config.progressInterval,
  })

  return task
}

export function upload (options: UploadOptions) {
  log('[RNBackgroundDownloader] download', options)
  if (!options.id || !options.url || !options.source)
    throw new Error('[RNBackgroundDownloader] id, url and destination are required')

  options.headers = { ...config.headers, ...options.headers }

  if (!(options.metadata && typeof options.metadata === 'object'))
    options.metadata = {}

  options.source = options.source.replace('file://', '')

  if (options.isAllowedOverRoaming == null) options.isAllowedOverRoaming = true
  if (options.isAllowedOverMetered == null) options.isAllowedOverMetered = true
  if (options.isNotificationVisible == null) options.isNotificationVisible = false

  const task = new SessionTask({
    id: options.id,
    type: 1, // Upload
    metadata: options.metadata,
  })
  tasksMap.set(options.id, task)

  NativeRNBackgroundDownloader.upload({
    ...options,
    metadata: JSON.stringify(options.metadata),
    progressInterval: config.progressInterval,
  })

  return task
}

export const directories = {
  documents: RNBackgroundDownloader.documents,
}

export default {
  download,
  upload,
  checkForExistingDownloads,
  ensureDownloadsAreRunning,
  completeHandler,

  setConfig,

  directories,
}
