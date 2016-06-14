let s:completion_script = expand('<sfile>:p:h:h').'/bin/completions.py'
let s:default_tags = [
      \ 'block', 'cache', 'for', 'if', 'with', 'autoescape',
      \ 'comment', 'filter', 'spaceless', 'verbatim']
let s:default_tags_pat = join(s:default_tags, '\|')
let s:midtags = '\(empty\|else\|elif\)'


function! s:get_completions() abort
  let group = ''
  let sig = ''
  let doc = ''
  let out = {}

  " This is really stupid, but whatever.
  for item in split(system('python "'.s:completion_script.'" 2>/dev/null'), "\n")
    if item =~# '^##'
      if !empty(group) && !empty(sig)
        call add(out[group], [sig, substitute(doc, '\\\\n', "\n", 'g')])
      endif

      let sig = item[2:]
      let doc = ''

      if group =~# '^htmldjango'
        let sig = matchstr(sig, '\%({% \||\)\zs\i\+\ze')
      endif
    elseif item =~# '^@@'
      if !empty(group) && !empty(sig)
        call add(out[group], [sig, substitute(doc, '\\\\n', "\n", 'g')])
        let sig = ''
        let doc = ''
      endif

      let group = item[2:]
      if !has_key(out, group)
        let out[group] = []
      endif
    else
      let doc .= item
    endif
  endfor

  return out
endfunction


function! djangoplus#get_completions(group) abort
  if !exists('s:completions')
    " Get completions from the shell's python interpreter.  This allows the
    " completions to actually match the version of Django that's in use.
    let s:completions = s:get_completions()
  endif

  if has_key(s:completions, a:group)
    return s:completions[a:group]
  endif

  return []
endfunction


" Run the existing omnifunc if it exists.
function! s:default_completion(findstart, base) abort
  if exists('b:orig_omnifunc') && !empty(b:orig_omnifunc)
    return call(b:orig_omnifunc, [a:findstart, a:base])
  endif

  if a:findstart == 1
    return -2
  else
    return []
  endif
endfunction


" Completions for Django python and HTML files.
function! djangoplus#complete(findstart, base) abort
  if !exists('b:orig_omnifunc')
    return s:default_completion(a:findstart, a:base)
  endif

  if !exists('b:is_django')
    return s:default_completion(a:findstart, a:base)
  endif

  if a:findstart == 1
    let s:do_assignment = 0
    let s:do_completion = 0
    let s:do_mix = 0
    let s:kind = ''
    let line = strpart(getline(line('.')), 0, col('.') - 1)
    let idx = -1
    let source_set = ''

    if &l:filetype =~# '\<python\>'
      if exists('b:is_django_settings')
        " In settings files, show setting completions
        let idx = match(line, '\<\zs\i*$')
        let s:do_mix = !has('nvim')
        let s:kind = 'conf'
        let source_set = 'settings'
      elseif line =~# '\<settings\.\i*$'
        " Matched right after `settings.`
        let idx = match(line, '\<settings\.\zs\i*$')
        let s:kind = 'conf'
        let source_set = 'settings'
      elseif line =~# '\.objects\.\i*$'
        " Matched right after `.objects.`
        let idx = match(line, '\.objects\.\zs\i*$')
        let s:kind = 'qs'
        let source_set = 'queryset'
      elseif line =~# '\i\+\.\i*$'
        " Any dot, but mix results with the previous completion function
        let idx = match(line, '\.\zs\i*$')
        let s:do_mix = !has('nvim')
        let s:kind = 'qs'
        let source_set = 'queryset'
      endif
    elseif &l:filetype =~# '\<htmldjango\>'
      if line =~# '{%\s\+\i*$'
        let idx = match(line, '{%\s\+\zs\i*$')
        let s:kind = 'tag'
        let source_set = 'htmldjangotags'
      elseif line =~# '|\i*$'
        let idx = match(line, '|\zs\i*$')
        let s:kind = 'filt'
        let source_set = 'htmldjangofilters'
      endif
    endif

    if idx != -1
      let s:do_completion = 1
      let s:do_assignment = source_set == 'settings' && strpart(line, 0, idx) !~ '=.*'
      let s:source = djangoplus#get_completions(source_set)

      if source_set == 'settings' || source_set =~# '^htmldjango'
        let s:word_pattern = '\i\+\ze'
      else
        let s:word_pattern = '\i\+\ze\%(\|\_$\)'
      endif

      if s:do_mix
        " Let the original omnifunc do its thing
        let s:orig_omnifunc_start = s:default_completion(1, '')
      endif
      return idx
    endif
  elseif s:do_completion
    let completions = []
    for item in s:source
      let word = matchstr(item[0], s:word_pattern)
      if word =~? '^'.a:base
        call add(completions, {
              \ 'word': word,
              \ 'abbr': item[0].(s:do_assignment ? ' = ' : ''),
              \ 'info': item[0]."\n\n".item[1],
              \ 'icase': 0,
              \ 'kind': s:kind,
              \ 'menu': '[Dj+]',
              \ })
      endif
    endfor

    if s:do_mix
      let orig_base = strpart(getline(v:lnum), s:orig_omnifunc_start)
      return s:default_completion(s:orig_omnifunc_start, orig_base) + completions
    endif

    return completions
  endif

  return s:default_completion(a:findstart, a:base)
endfunction


" Tag scanning.  This sets b:blocktags by searching for {% end* %} tags
" allowing custom tags to be indented correctly as well.
function! djangoplus#scan_template_tags() abort
  let view = winsaveview()
  let reg_val = getreg('a')
  let reg_type = getregtype('a')

  " Cobble together all matching lines...
  normal! qaq
  silent g/{%\s\+\<end\S\+\>/y A
  let matches = getreg('a')

  call setreg('a', reg_val, reg_type)
  call histdel('search', -1)
  let @/ = histget('search', -1)
  call winrestview(view)

  let blocktags = []

  " ...then strip out the garbage and split on whitespace
  for tag in split(substitute(matches,
        \ '\%(\%(\_^\|\_.\{-}\){%\s\+\<end\(\i\+\)\>\)\%([^{]*\)\|.*$', '\1 ', 'g'))
    if index(s:default_tags, tag) == -1 && index(blocktags, tag) == -1
      call add(blocktags, tag)
    endif
  endfor

  if !empty(blocktags)
    let b:blocktags = join(blocktags, '\|')
  endif
endfunction


" Note: The after/ftplugin/htmldjango.vim script fills `b:blocktags` with more
" blocks it finds on load/save.
function! djangoplus#htmldjango_indent(...) abort
  if a:0 && a:1 == '.'
    let v:lnum = line('.')
  elseif a:0 && a:1 =~ '^\d'
    let v:lnum = a:1
  endif
  let vcol = col('.')

  call cursor(v:lnum,vcol)

  exe 'let ind = '.b:djangoplus_indentexpr

  let lnum = prevnonblank(v:lnum-1)
  let pnb = getline(lnum)
  let cur = getline(v:lnum)

  let tagstart = '.*' . '{%-\?\s*'
  let tagend = '.*-\?%}' . '.*'

  let blocktags = s:default_tags_pat
  let buffer_tags = get(b:, 'blocktags', '')
  if !empty(buffer_tags)
    let blocktags .= '\|'.buffer_tags
  endif
  let blocktags = '\('.blocktags.'\)'

  let pnb_blockstart = pnb =~# tagstart . blocktags . tagend
  let pnb_blockend   = pnb =~# tagstart . 'end' . blocktags . tagend
  let pnb_blockmid   = pnb =~# tagstart . s:midtags . tagend

  let cur_blockstart = cur =~# tagstart . blocktags . tagend
  let cur_blockend   = cur =~# tagstart . 'end' . blocktags . tagend
  let cur_blockmid   = cur =~# tagstart . s:midtags . tagend

  if pnb_blockstart && !pnb_blockend && pnb_blockstart != pnb_blockend
    let ind = ind + &sw
  elseif pnb_blockmid && !pnb_blockend && pnb_blockmid != pnb_blockstart && pnb_blockmid != pnb_blockend
    let ind = ind + &sw
  endif

  if cur_blockend && !cur_blockstart && cur_blockend != cur_blockstart
    let ind = ind - &sw
  elseif cur_blockmid && cur_blockmid != cur_blockstart && cur_blockmid != cur_blockend
    let ind = ind - &sw
  endif

  return ind
endfunction