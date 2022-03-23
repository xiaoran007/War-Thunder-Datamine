let nameFilter = require("nameFilter.nut")
let {set_kb_focus} = require("daRg")

return @(filterString, selectedCompName) nameFilter(filterString, {
  placeholder = "Filter by name"

  function onChange(text) {
    filterString.update(text)

    if ((text.len() > 0 ) && selectedCompName.value
      && !selectedCompName.value.contains(text)) {
      selectedCompName.update(null)
    }
  }

  function onEscape() {
    if (filterString.value != "")
      filterString("")
    else
      set_kb_focus(null)
  }
})

