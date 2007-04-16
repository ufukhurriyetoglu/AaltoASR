#ifndef DISTRIBUTIONS_HH
#define DISTRIBUTIONS_HH

#include "gmd.h"
#include "lavd.h"
#include "FeatureBuffer.hh"
#include "LinearAlgebra.hh"


class PDF {
public:
  virtual ~PDF() {}
  /* The feature dimensionality */
  int dim() const { return m_dim; }

  /* Different training modes */
  enum EstimationMode { ML, MMI };
  
  /* The likelihood of the current feature given this model */
  virtual double compute_likelihood(const FeatureVec &f) const = 0;
  /* The log likelihood of the current feature given this model */
  virtual double compute_log_likelihood(const FeatureVec &f) const = 0;
  /* Write the parameters of this distribution to the stream os */
  virtual void write(std::ostream &os) const = 0;
  /* Read the parameters of this distribution from the stream is */
  virtual void read(std::istream &is) = 0;

  /* Set the current estimation mode */
  void set_estimation_mode(EstimationMode m) { m_mode = m; };
  /* Get the current estimation mode */
  EstimationMode get_estimation_mode() { return m_mode; };

protected:
  EstimationMode m_mode;
  int m_dim;
};


class Gaussian : public PDF {
public:
  
  // ABSTRACT FUNCTIONS, SHOULD BE OVERWRITTEN IN THE GAUSSIAN IMPLEMENTATIONS

    /* Resets the Gaussian to have dimensionality dim and all values zeroed */
  virtual void reset(int dim) = 0;
  /* Initializes the accumulator buffers */  
  virtual void start_accumulating() = 0;
  /* Accumulates the maximum likelihood statistics for the Gaussian
     weighed with a prior. */
  virtual void accumulate_ml(double prior, const FeatureVec &f) = 0;
  /* Accumulates the maximum mutual information denominator statistics
     weighed with priors. The numerator statistics should be accumulated
     using the accumulate_ml function */
  virtual void accumulate_mmi_denominator(std::vector<double> priors,
					  std::vector<const FeatureVec*> const features) = 0;
  /* Use the accumulated statistics to update the current model parameters.
     Empties the accumulators */
  virtual void estimate_parameters() = 0;
  /* Returns the mean vector for this Gaussian */
  virtual void get_mean(Vector &mean) const = 0;
  /* Returns the covariance matrix for this Gaussian */
  virtual void get_covariance(Matrix &covariance) const = 0;
  /* Sets the mean vector for this Gaussian */
  virtual void set_mean(const Vector &mean) = 0;
  /* Sets the covariance matrix for this Gaussian */
  virtual void set_covariance(const Matrix &covariance) = 0;
  
  // THESE FUNCTIONS HAVE ALSO A COMMON IMPLEMENTATION, BUT CAN BE OVERWRITTEN

  /* Splits the current Gaussian to two by disturbing the mean */
  virtual void split(Gaussian &s1, Gaussian &s2) const;
  /* Sets the parameters for the current Gaussian by merging m1 and m2 */
  virtual void merge(double w1, const Gaussian &m1, double w2, const Gaussian &m2);
  /* Compute the Kullback-Leibler divergence KL(current||g) */
  virtual double kullback_leibler(Gaussian &g) const;
};


class DiagonalAccumulator {
public:
  DiagonalAccumulator(int dim) { 
    ml_mean.resize(dim);
    ml_cov.resize(dim);
    mmi_mean.resize(dim);
    mmi_cov.resize(dim);
    ml_mean=0;
    mmi_mean=0;
    ml_cov=0;
    mmi_cov=0;
  };
  Vector ml_mean;
  Vector mmi_mean;
  Vector ml_cov;
  Vector mmi_cov;
};


class DiagonalGaussian : public Gaussian {
public:
  DiagonalGaussian(int dim);
  DiagonalGaussian(const DiagonalGaussian &g);
  ~DiagonalGaussian();
  virtual void reset(int dim);

  // From pdf
  virtual double compute_likelihood(const FeatureVec &f);
  virtual double compute_log_likelihood(const FeatureVec &f);
  virtual void write(std::ostream &os);
  virtual void read(std::istream &is);

  // Gaussian-specific
  virtual void start_accumulating();
  virtual void accumulate_ml(double prior,
			     const FeatureVec &f);
  virtual void accumulate_mmi_denominator(std::vector<double> priors,
					  std::vector<const FeatureVec*> const features);
  virtual void estimate_parameters();
  virtual void get_mean(Vector &mean) const;
  virtual void get_covariance(Matrix &covariance) const;
  virtual void set_mean(const Vector &mean);
  virtual void set_covariance(const Matrix &covariance);

  // Diagonal-specific
  /* Get the diagonal of the covariance matrix */
  void get_covariance(Vector &covariance) const;
  /* Set the diagonal of the covariance matrix */
  void set_covariance(const Vector &covariance);

private:
  double m_constant;

  Vector m_mean;
  Vector m_covariance;
  Vector m_precision;

  DiagonalAccumulator *m_accum;
};


class FullCovarianceAccumulator {
public:
  FullCovarianceAccumulator(int dim) { 
    ml_mean.resize(dim);
    ml_cov.resize(dim,dim);
    mmi_mean.resize(dim);
    mmi_cov.resize(dim,dim);
    outer.resize(dim,dim);
    ml_mean=0;
    mmi_mean=0;
    ml_cov=0;
    mmi_cov=0;
    outer=0;
  };
  Vector ml_mean;
  Vector mmi_mean;
  Matrix ml_cov;
  Matrix mmi_cov;
  Matrix outer;
};


class FullCovarianceGaussian : public Gaussian {
public:
  FullCovarianceGaussian(int dim);
  FullCovarianceGaussian(const FullCovarianceGaussian &g);
  ~FullCovarianceGaussian();
  virtual void reset(int dim);

  // From pdf
  virtual double compute_likelihood(const FeatureVec &f);
  virtual double compute_log_likelihood(const FeatureVec &f);
  virtual void write(std::ostream &os);
  virtual void read(std::istream &is);

  // Gaussian-specific
  virtual void start_accumulating();
  virtual void accumulate_ml(double prior,
			     const FeatureVec &f);
  virtual void accumulate_mmi_denominator(std::vector<double> priors,
					  std::vector<const FeatureVec*> const features);
  virtual void estimate_parameters();
  virtual void get_mean(Vector &mean) const;
  virtual void get_covariance(Matrix &covariance) const;
  virtual void set_mean(const Vector &mean);
  virtual void set_covariance(const Matrix &covariance);
  
private:
  double m_determinant;
  double m_constant;

  // Parameters
  Vector m_mean;
  Matrix m_covariance;
  Matrix m_precision;

  FullCovarianceAccumulator *m_accum;
};


class PrecisionSubspace {
public:
  PrecisionSubspace(int dim);
  ~PrecisionSubspace();
  void set_dim(int dim) { m_dim = dim; };
  int dim() const { return m_dim; };
private:
  int m_dim;
};


class PrecisionConstrainedGaussian : public Gaussian {
public:
  PrecisionConstrainedGaussian(int dim);
  ~PrecisionConstrainedGaussian();
  virtual void reset(int dim);

  // From pdf
  virtual double compute_likelihood(const FeatureVec &f);
  virtual double compute_log_likelihood(const FeatureVec &f);
  virtual void write(std::ostream &os);
  virtual void read(std::istream &is);

  // Gaussian-specific
  virtual void start_accumulating();
  virtual void accumulate_ml(double prior, const FeatureVec &f);
  virtual void accumulate_mmi_denominator(std::vector<double> priors,
					  std::vector<const FeatureVec*> const features);
  virtual void estimate_parameters();
  virtual void get_mean(Vector &mean) const;
  virtual void get_covariance(Matrix &covariance) const;
  virtual void set_mean(Vector &mean);
  virtual void set_covariance(Matrix &covariance);

  // PCGMM-specific
  /* Get the coefficients for the subspace constrained precision matrix */
  Vector &get_precision_coeffs() const;
  /* Set the coefficients for the subspace constrained precision matrix */
  void set_precision_coeffs(Vector &coeffs);

private:
  double m_determinant;
  Vector m_mean;
  Vector m_precision_coeffs;
  PrecisionSubspace m_ps;
};


class ExponentialSubspace {
public:
  ExponentialSubspace(int dim);
  ~ExponentialSubspace();
  void set_dim(int dim) { m_dim = dim; }
  int dim() const { return m_dim; }
private:
  int m_dim;
};



class SubspaceConstrainedGaussian : public Gaussian {
public:
  SubspaceConstrainedGaussian(int dim);
  ~SubspaceConstrainedGaussian();
  virtual void reset(int dim);

  // From pdf
  virtual double compute_likelihood(const FeatureVec &f);
  virtual double compute_log_likelihood(const FeatureVec &f);
  virtual void write(std::ostream &os);
  virtual void read(std::istream &is);

  // Gaussian-specific
  virtual void start_accumulating();
  virtual void accumulate_ml(double prior, const FeatureVec &f);
  virtual void accumulate_mmi_denominator(std::vector<double> priors,
					  std::vector<const FeatureVec*> const features);
  virtual void estimate_parameters();
  virtual void get_mean(Vector &mean) const;
  virtual void get_covariance(Matrix &covariance) const;
  virtual void set_mean(Vector &mean);
  virtual void set_covariance(Matrix &covariance);

  // SCGMM-specific
  /* Get the coefficients for the subspace constrained exponential parameters */
  Vector &get_subspace_coeffs() const;
  /* Set the coefficients for the subspace constrained exponential parameters */
  void set_subspace_coeffs(Vector &coeffs);

private:
  Vector m_subspace_coeffs;
  ExponentialSubspace m_es;
};


class PDFPool {
public:

  PDFPool() { m_dim=0; };
  PDFPool(int dim) { m_dim=dim; };
  ~PDFPool();
  /* The dimensionality of the distributions in this pool */
  int dim() const { return m_dim; }
  /* The dimensionality of the distributions in this pool */
  int size() const { return m_pool.size(); };
  /* Reset everything */
  void reset();

  /* Get the pdf from the position index */
  PDF* get_pdf(int index);
  /* Set the pdf in the position index */
  void set_pdf(int index, PDF *pdf);

  /* Read the distributions from a .gk -file */
  void read_gk(const std::string &filename);
  /* Write the distributions to a .gk -file */
  void write_gk(const std::string &filename) const;

  /* Reset the cache */
  void reset_cache();
  /* Compute all likelihoods to the cache */
  void cache_likelihood(const FeatureVec &f);
  /* Compute likelihood of one pdf to the cache */
  void cache_likelihood(const FeatureVec &f, int index);
  /* Compute likelihoods of pdfs given in indices to the cache */
  void cache_likelihood(const FeatureVec &f,
			const std::vector<int> &indices);
  /* Instant computation of pdf at position index */
  double compute_likelihood(const FeatureVec &f, int index);
  /* Get the likelihood from the cache */
  inline double get_likelihood(int index) const;
  
private:
  std::vector<PDF*> m_pool;
  std::vector<double> m_likelihoods;
  int m_dim;
};


class Mixture : public PDF {
public:
  // Mixture-specific
  Mixture();
  Mixture(PDFPool *pool);
  ~Mixture();
  int size() { return m_pointers.size(); };
  void reset();
  void set_pool(PDFPool *pool);
  /* Set the mixture components, clear existing mixture */
  void set_components(const std::vector<int> &pointers,
		      const std::vector<double> &weights);
  /* Get the mixture components */
  void get_components(std::vector<int> &pointers,
		      std::vector<double> &weights);
  /* Add one new component to the mixture. 
     Doesn't normalize the coefficients in between */
  void add_component(int pool_index, double weight);
  /* Normalize the weights to have a sum of 1 */
  void normalize_weights();
  /* Compute the likelihood from cached base function likelihoods */
  double compute_likelihood() const;
  /* Compute the log likelihood from cached base function likelihoods */
  double compute_log_likelihood() const;



  // From pdf
  /* Compute the likelihood in-place, not from cache */
  virtual double compute_likelihood(const FeatureVec &f) const;
  /* Compute the likelihood in-place, not from cache */
  virtual double compute_log_likelihood(const FeatureVec &f) const;
  virtual void write(std::ostream &os) const;
  virtual void read(std::istream &is);

private:
  std::vector<int> m_pointers;
  std::vector<double> m_weights;
  PDFPool *m_pool;
};


#endif /* HMMSET_HH */