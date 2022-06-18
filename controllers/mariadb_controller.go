/*
Copyright 2022.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controllers

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	databasev1alpha1 "github.com/mmontes11/mariadb-operator/api/v1alpha1"
	"github.com/mmontes11/mariadb-operator/pkg/builders"
)

// MariaDBReconciler reconciles a MariaDB object
type MariaDBReconciler struct {
	client.Client
	Scheme             *runtime.Scheme
	StatefulSetBuilder *builders.StatefulSetBuilder
	ServiceBuilder     *builders.ServiceBuilder
}

//+kubebuilder:rbac:groups=database.mmontes.io,resources=mariadbs,verbs=get;list;watch;create;update;patch;delete
//+kubebuilder:rbac:groups=database.mmontes.io,resources=mariadbs/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=database.mmontes.io,resources=mariadbs/finalizers,verbs=update

// Reconcile is part of the main kubernetes reconciliation loop which aims to
// move the current state of the cluster closer to the desired state.
// TODO(user): Modify the Reconcile function to compare the state specified by
// the MariaDB object against the actual cluster state, and then
// perform operations to make the cluster state reflect the state specified by
// the user.
//
// For more details, check Reconcile and its Result here:
// - https://pkg.go.dev/sigs.k8s.io/controller-runtime@v0.11.2/pkg/reconcile
func (r *MariaDBReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	_ = log.FromContext(ctx)

	var mariadb databasev1alpha1.MariaDB
	if err := r.Get(ctx, req.NamespacedName, &mariadb); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	var existingSts appsv1.StatefulSet
	if err := r.Get(ctx, req.NamespacedName, &existingSts); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, fmt.Errorf("error getting StatefulSet: %v", err)
		}

		if err := r.createStatefulSet(ctx, &mariadb); err != nil {
			return ctrl.Result{}, fmt.Errorf("error creating StatefulSet: %v", err)
		}
	}

	var existingSvc corev1.Service
	if err := r.Get(ctx, req.NamespacedName, &existingSvc); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, fmt.Errorf("error getting Service: %v", err)
		}

		if err := r.createService(ctx, &mariadb); err != nil {
			return ctrl.Result{}, fmt.Errorf("error creating Service: %v", err)
		}
	}

	return ctrl.Result{}, nil
}

func (r *MariaDBReconciler) createStatefulSet(ctx context.Context, mariadb *databasev1alpha1.MariaDB) error {
	sts, err := r.StatefulSetBuilder.Build(ctx, mariadb)
	if err != nil {
		return fmt.Errorf("error building StatefulSet %v", err)
	}
	if err := controllerutil.SetControllerReference(mariadb, sts, r.Scheme); err != nil {
		return fmt.Errorf("error setting controller reference to StatefulSet: %v", err)
	}

	if err := r.Create(ctx, sts); err != nil {
		return fmt.Errorf("error creating StatefulSet on API server: %v", err)
	}
	return nil
}

func (r *MariaDBReconciler) createService(ctx context.Context, mariadb *databasev1alpha1.MariaDB) error {
	svc := r.ServiceBuilder.Build(mariadb)
	if err := controllerutil.SetControllerReference(mariadb, svc, r.Scheme); err != nil {
		return fmt.Errorf("error setting controller reference to Service: %v", err)
	}

	if err := r.Create(ctx, svc); err != nil {
		return fmt.Errorf("error creating Service on API server: %v", err)
	}
	return nil
}

// SetupWithManager sets up the controller with the Manager.
func (r *MariaDBReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&databasev1alpha1.MariaDB{}).
		Owns(&appsv1.StatefulSet{}).
		Owns(&corev1.Service{}).
		Complete(r)
}
