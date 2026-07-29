import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { defineConfig } from 'vite'

const libraryRoot = '/Users/fletcher/Music/Qobuz'
const audioExtensions = new Set(['.flac', '.mp3', '.m4a', '.aac', '.wav', '.ogg', '.opus'])
const genreCache = new Map()

function readGenre(filePath) {
  if (!filePath) return 'Unknown Genre'
  if (genreCache.has(filePath)) return genreCache.get(filePath)
  let genre = 'Unknown Genre'
  try {
    genre = execFileSync('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format_tags=genre',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      filePath,
    ], { encoding: 'utf8', timeout: 3000 }).trim().split(/\r?\n/)[0] || genre
  } catch {}
  genreCache.set(filePath, genre)
  return genre
}

function mediaUrl(relativePath) {
  return `/qobuz-media/${relativePath.split(path.sep).map(encodeURIComponent).join('/')}`
}

function readLibrary() {
  const albums = fs.readdirSync(libraryRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => {
      const match = entry.name.match(/^(.*?) - (.*) \((\d{4})\) \[([^\]]+)\]$/)
      const artist = match?.[1] || 'Unknown artist'
      const title = match?.[2] || entry.name
      const year = match?.[3] || ''
      const quality = match?.[4] || ''
      const directory = path.join(libraryRoot, entry.name)
      const filenames = fs.readdirSync(directory)
      const coverName = filenames.find((name) => /^(cover|folder)\.(jpe?g|png|webp)$/i.test(name))
      const cover = coverName ? mediaUrl(path.join(entry.name, coverName)) : ''
      const audioFilenames = filenames
        .filter((name) => audioExtensions.has(path.extname(name).toLowerCase()))
        .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))
      const genre = readGenre(audioFilenames[0] ? path.join(directory, audioFilenames[0]) : '')
      const tracks = audioFilenames
        .map((name, index) => ({
          id: path.join(entry.name, name),
          number: Number(name.match(/^(\d+)/)?.[1]) || index + 1,
          title: path.basename(name, path.extname(name)).replace(/^\d+\.\s*/, ''),
          artist,
          album: title,
          year,
          quality,
          genre,
          cover,
          audio: mediaUrl(path.join(entry.name, name)),
        }))

      return { id: entry.name, title, artist, year, quality, genre, cover, tracks }
    })
    .sort((a, b) => a.artist.localeCompare(b.artist) || a.title.localeCompare(b.title))

  return {
    source: libraryRoot,
    albums,
    tracks: albums.flatMap((album) => album.tracks),
  }
}

function sendMedia(request, response, next) {
  if (!request.url?.startsWith('/qobuz-media/')) return next()

  const pathname = new URL(request.url, 'http://localhost').pathname
  const relativePath = pathname.slice('/qobuz-media/'.length).split('/').map(decodeURIComponent).join(path.sep)
  const filePath = path.resolve(libraryRoot, relativePath)
  if (!filePath.startsWith(`${path.resolve(libraryRoot)}${path.sep}`) || !fs.existsSync(filePath)) {
    response.statusCode = 404
    return response.end('Not found')
  }

  const stat = fs.statSync(filePath)
  const extension = path.extname(filePath).toLowerCase()
  const contentTypes = {
    '.flac': 'audio/flac', '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.aac': 'audio/aac',
    '.wav': 'audio/wav', '.ogg': 'audio/ogg', '.opus': 'audio/ogg', '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp',
  }
  response.setHeader('Content-Type', contentTypes[extension] || 'application/octet-stream')
  response.setHeader('Accept-Ranges', 'bytes')
  response.setHeader('Cache-Control', 'no-cache')

  const range = request.headers.range
  if (range) {
    const [startText, endText] = range.replace('bytes=', '').split('-')
    const start = Number(startText)
    const end = endText ? Number(endText) : stat.size - 1
    if (!Number.isFinite(start) || start < 0 || end >= stat.size || start > end) {
      response.statusCode = 416
      response.setHeader('Content-Range', `bytes */${stat.size}`)
      return response.end()
    }
    response.statusCode = 206
    response.setHeader('Content-Range', `bytes ${start}-${end}/${stat.size}`)
    response.setHeader('Content-Length', end - start + 1)
    return fs.createReadStream(filePath, { start, end }).pipe(response)
  }

  response.setHeader('Content-Length', stat.size)
  fs.createReadStream(filePath).pipe(response)
}

export default defineConfig({
  plugins: [{
    name: 'qobuz-library',
    configureServer(server) {
      server.middlewares.use('/api/library', (_request, response) => {
        try {
          response.setHeader('Content-Type', 'application/json; charset=utf-8')
          response.setHeader('Cache-Control', 'no-store')
          response.end(JSON.stringify(readLibrary()))
        } catch (error) {
          response.statusCode = 500
          response.end(JSON.stringify({ error: error.message }))
        }
      })
      server.middlewares.use(sendMedia)
      server.watcher.add(libraryRoot)
      server.watcher.on('all', (_event, changedPath) => {
        if (changedPath.startsWith(libraryRoot)) server.ws.send({ type: 'full-reload' })
      })
    },
  }],
})
