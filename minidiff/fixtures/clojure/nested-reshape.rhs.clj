(defn render-user
  [user]
  {:id (:id user)
   :profile {:name (:name user)
             :email (:email user)}
   :admin? (:admin user)})
