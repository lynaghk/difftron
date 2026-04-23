(defn render-user [user]
  {:id (:id user)
   :name (:name user)
   :details {:email (:email user)
             :admin? (:admin user)}})
