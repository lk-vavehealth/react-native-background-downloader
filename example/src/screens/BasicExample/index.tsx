import React, { useEffect, useState } from 'react'
import { StyleSheet, View, Text, FlatList, Platform } from 'react-native'
import RNFS from 'react-native-fs'
import {
  completeHandler,
  directories,
  checkForExistingDownloads,
  download,
  setConfig,
  SessionTask,
} from '@kesha-antonov/react-native-background-downloader'
import Slider from '@react-native-community/slider'
import { ExButton, ExWrapper } from '../../components/commons'
import { toast, uuid } from '../../utils'

const defaultDir = directories.documents

setConfig({
  isLogsEnabled: true,
})

const Footer = ({
  onStart,
  onStop,
  onReset,
  onClear,
  onRead,
  isStarted,
  ...props
}) => {
  return (
    <View style={styles.headerWrapper} {...props}>
      {isStarted
        ? (
          <ExButton title={'Stop'} onPress={onStop} />
        )
        : (
          <ExButton title={'Start'} onPress={onStart} />
        )}

      <ExButton title={'Reset'} onPress={onReset} />
      <ExButton title={'Delete files'} onPress={onClear} />
      <ExButton title={'List files'} onPress={onRead} />
    </View>
  )
}

const BasicExampleScreen = () => {
  const [urlList] = useState([
    {
      id: uuid(),
      url: 'https://sabnzbd.org/tests/internetspeed/20MB.bin',
    },
    {
      id: uuid(),
      url: 'https://sabnzbd.org/tests/internetspeed/50MB.bin',
    },
    {
      id: uuid(),
      url: 'https://proof.ovh.net/files/100Mb.dat',
    },
  ])

  const [isStarted, setIsStarted] = useState(false)

  const [sessionTasks, setSessionTasks] = useState<SessionTask[]>([])

  /**
   * It is used to resume your incomplete or unfinished downloads.
   */
  const resumeExistingTasks = async () => {
    try {
      const tasks = await checkForExistingDownloads()

      console.log(tasks)

      if (tasks.length > 0) {
        tasks.map(task => process(task))
        setSessionTasks(sessionTasks => [...sessionTasks, ...tasks])
        setIsStarted(true)
      }
    } catch (e) {
      console.warn('checkForExistingDownloads e', e)
    }
  }

  const readStorage = async () => {
    const files = await RNFS.readdir(defaultDir)
    toast('Check logs')
    console.log(`Downloaded files: ${files}`)
  }

  const clearStorage = async () => {
    const files = await RNFS.readdir(defaultDir)

    if (files.length > 0)
      await Promise.all(
        files.map(file => RNFS.unlink(defaultDir + '/' + file))
      )

    toast('Check logs')
    console.log(`Deleted file count: ${files.length}`)
  }

  const process = task => {
    const { index } = getTask(task.id)

    return task
      .begin(({ expectedBytes, headers }) => {
        console.log('task: begin', { id: task.id, expectedBytes, headers })
        setSessionTasks(sessionTasks => {
          sessionTasks[index] = task
          return [...sessionTasks]
        })
      })
      .progress(({ bytes, bytesTotal }) => {
        console.log('task: progress', { id: task.id, bytes, bytesTotal })
        setSessionTasks(sessionTasks => {
          sessionTasks[index] = task
          return [...sessionTasks]
        })
      })
      .done(() => {
        console.log('task: done', { id: task.id })
        setSessionTasks(sessionTasks => {
          sessionTasks[index] = task
          return [...sessionTasks]
        })

        completeHandler(task.id)
      })
      .error(e => {
        console.error('task: error', { id: task.id, e })
        setSessionTasks(sessionTasks => {
          sessionTasks[index] = task
          return [...sessionTasks]
        })

        completeHandler(task.id)
      })
  }

  const reset = () => {
    stop()
    setSessionTasks([])
    setIsStarted(false)
  }

  const start = () => {
    /**
     * You need to provide the extension of the file in the destination section below.
     * If you cannot provide this, you may experience problems while using your file.
     * For example; Path + File Name + .png
     */
    const taskAttributes = urlList.map(item => {
      const destination = defaultDir + '/' + item.id
      return {
        id: item.id,
        url: item.url,
        destination,
      }
    })

    const tasks = taskAttributes.map(taskAttribute =>
      process(download(taskAttribute))
    )

    setSessionTasks(sessionTasks => [...sessionTasks, ...tasks])
    setIsStarted(true)
  }

  const stop = () => {
    const tasks = sessionTasks.map(task => {
      task.stop()
      return task
    })

    setSessionTasks(tasks)
    setIsStarted(false)
  }

  const pause = id => {
    const { index, task } = getTask(id)

    task.pause()
    setSessionTasks(sessionTasks => {
      sessionTasks[index] = task
      return [...sessionTasks]
    })
  }

  const resume = id => {
    const { index, task } = getTask(id)

    task.resume()
    setSessionTasks(sessionTasks => {
      sessionTasks[index] = task
      return [...sessionTasks]
    })
  }

  const cancel = id => {
    const { index, task } = getTask(id)

    task.stop()
    setSessionTasks(sessionTasks => {
      sessionTasks[index] = task
      return [...sessionTasks]
    })
  }

  const getTask = id => {
    const index = sessionTasks.findIndex(task => task.id === id)
    const task = sessionTasks[index]
    return { index, task }
  }

  useEffect(() => {
    resumeExistingTasks()
  }, [])

  return (
    <ExWrapper>
      <Text style={styles.title}>Basic Example</Text>
      <View>
        <FlatList
          data={urlList}
          keyExtractor={(item, index) => `url-${index}`}
          renderItem={({ index, item }) => (
            <View style={styles.item}>
              <View style={styles.itemContent}>
                <Text>Id: {item.id}</Text>
                <Text>Url: {item.url}</Text>
              </View>
            </View>
          )}
          ListFooterComponent={() => (
            <Footer
              isStarted={isStarted}
              onStart={start}
              onStop={stop}
              onReset={reset}
              onClear={clearStorage}
              onRead={readStorage}
            />
          )}
        />
      </View>
      <FlatList
        style={{ flex: 1, flexGrow: 1 }}
        data={sessionTasks}
        renderItem={({ item, index }) => {
          const isEnded = ['STOPPED', 'DONE', 'FAILED'].includes(item.state)
          const isDownloading = item.state === 'PROCESSING'
          const processingState = item.type === 0 ? 'DOWNLOADING' : 'UPLOADING'

          return (
            <View style={styles.item}>
              <View style={styles.itemContent}>
                <Text>{item?.id}</Text>
                <Text>{processingState}</Text>
                <Slider
                  disabled={true}
                  value={item?.bytes}
                  minimumValue={0}
                  maximumValue={item?.bytesTotal}
                />
              </View>
              <View>
                {!isEnded &&
                  (isDownloading
                    ? (
                      <ExButton title={'Pause'} onPress={() => pause(item.id)} />
                    )
                    : (
                      <ExButton
                        title={'Resume'}
                        onPress={() => resume(item.id)}
                      />
                    ))}
                <ExButton title={'Cancel'} onPress={() => cancel(item.id)} />
              </View>
            </View>
          )
        }}
        keyExtractor={(item, index) => `task-${index}`}
      />
    </ExWrapper>
  )
}

const styles = StyleSheet.create({
  headerWrapper: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-evenly',
    padding: 6,
  },
  title: {
    fontSize: 24,
    fontWeight: '500',
    textAlign: 'center',
    alignSelf: 'center',
    marginTop: 16,
  },
  item: {
    padding: 8,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  itemContent: {
    flex: 1,
    flexShrink: 1,
  },
})

export default BasicExampleScreen
