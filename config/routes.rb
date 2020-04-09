Scuclasses::Application.routes.draw do
  match 'search' => 'home#search', :via => [:get, :post]
  match 'advanced_search' => 'home#advanced_search', :via => [:get, :post]
  match 'rt_search' => 'home#rt_search', :via => [:get, :post]
  match 'sections' => 'home#sections', :via => [:get, :post]

  root :to => 'home#index'
end
