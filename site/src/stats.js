import { REPO_SLUG } from './config.js'

// Everything here is public GitHub data, read from the visitor's browser with no key or backend.
const $ = (id) => document.getElementById(id)
const number = (value) => value.toLocaleString('en-US')
const api = (path) => fetch(`https://api.github.com/repos/${REPO_SLUG}${path}`, { headers: { Accept: 'application/vnd.github+json' } })

function showReleases(releases) {
  const rows = releases.map((release) => ({
    tag: release.tag_name,
    date: release.published_at,
    count: release.assets.reduce((sum, asset) => sum + asset.download_count, 0),
  }))
  const total = rows.reduce((sum, row) => sum + row.count, 0)
  const top = Math.max(...rows.map((row) => row.count), 1)

  $('total').textContent = number(total)
  $('status').textContent = `Across ${rows.length} ${rows.length === 1 ? 'release' : 'releases'}. Counted by GitHub.`
  $('latest').textContent = rows[0].tag
  $('releases').replaceChildren(...rows.map((row) => {
    const item = document.createElement('li')
    item.className = 'release'
    item.title = `${row.tag}: ${number(row.count)} downloads, published ${new Date(row.date).toLocaleDateString('en-GB', { dateStyle: 'medium' })}`
    const tag = document.createElement('span')
    tag.className = 'release-tag'
    tag.textContent = row.tag
    const track = document.createElement('span')
    track.className = 'release-track'
    const bar = document.createElement('span')
    bar.className = 'release-bar'
    bar.style.display = 'block'
    bar.style.width = `${(row.count / top) * 100}%`
    track.append(bar)
    const count = document.createElement('span')
    count.className = 'release-count'
    count.textContent = number(row.count)
    item.append(tag, track, count)
    return item
  }))
}

async function load() {
  const [repo, releases] = await Promise.all([api(''), api('/releases?per_page=100')])
  if (repo.status === 403 || releases.status === 403) {
    $('status').textContent = 'GitHub is rate limiting this browser. Try again in a little while.'
    return
  }
  if (!repo.ok) {
    $('status').textContent = 'The repository isn’t public yet, so there are no numbers to show.'
    return
  }
  const info = await repo.json()
  $('stars').textContent = number(info.stargazers_count)
  $('forks').textContent = number(info.forks_count)
  $('issues').textContent = number(info.open_issues_count)

  const list = releases.ok ? (await releases.json()).filter((release) => !release.draft) : []
  if (list.length) showReleases(list)
  else $('status').textContent = 'No release has been published yet.'
}

load().catch(() => { $('status').textContent = 'Couldn’t reach GitHub.' })
