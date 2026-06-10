import * as esbuild from 'esbuild'

const isProduction = process.env.NODE_ENV === 'production'

const config = {
  entryPoints: ['app/javascript/*.*'],
  bundle: true,
  sourcemap: true,
  format: 'esm',
  outdir: 'app/assets/builds',
  publicPath: '/assets'
}

if (isProduction) {
  config.define = { 'process.env.NODE_ENV': '"production"' }
  config.minify = true
}

if (process.argv.includes('--watch')) {
  const context = await esbuild.context({ ...config, logLevel: 'info' })
  await context.watch()
} else {
  await esbuild.build({ ...config, logLevel: 'info' })
}
